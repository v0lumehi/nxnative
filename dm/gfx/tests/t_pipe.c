// Frame pipelining's page classification (nvn_dirty.c "Frame pipelining"): pages a binding reads directly are write-protected with the reading submission's fence (cold) or,
// once the CPU writes them, hot (the caller shadows them). Checked without a GPU: the "completed fence" is a variable of the test.
//   1. an unclassified page is not hot; nvn_pipe_direct protects it and stamps the fence
//   2. a guest write to it while that fence has not completed waits until it has (a second thread advances the fence after 100 ms), then goes through; the page is hot
//   3. a write after the fence completed does not wait
//   4. a hot page read directly again (a binding that cannot take a shadow) is protected again and cold
//   5. probes: a hot page left unwritten for 4 presents turns cold; one written after its probe stays hot (and the write did not wait: its readers read shadows)
//   6. a host write (not guest code) never waits and forgets the classification; the next direct read protects the page again
//   7. a new pool over the same memory starts unclassified
//   8. a page no binding has read can be taken as hot at once (adopt) and cools when left alone; its first write does not wait
//   (5 also: a page that turns hot again after cooling stays hot for good)
#include "../nvn/nvn_dirty.h"
#include "../../host/dm.h"
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

module_t g_mod[MAX_MOD];
int g_nmod;
module_t *module_of(const void *p) { (void)p; return NULL; }
void crash_install(void);

static int g_fail;
#define EXPECT(name, want, got) do { \
    long long want_ = (long long)(want), got_ = (long long)(got); \
    printf("%-64s expected %-4lld → got %-4lld %s\n", name, want_, got_, want_ == got_ ? "✓" : "✗"); \
    if (want_ != got_) g_fail++; \
} while (0)

static _Atomic uint64_t g_done;
static _Atomic int g_guest = 1;
static uint64_t done_fn(void) { return atomic_load(&g_done); }
static int guest_fn(void *uc) { (void)uc; return atomic_load(&g_guest); }
static double now_ms(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1e3 + t.tv_nsec / 1e6; }
static void *advance(void *arg) { usleep(100000); atomic_store(&g_done, (uint64_t)(uintptr_t)arg); return NULL; }
static double timed_write(volatile uint8_t *p, uint8_t v) { double t0 = now_ms(); *p = v; return now_ms() - t0; }
static uint64_t stat(int i) { uint64_t s[13]; nvn_pipe_stats(s); return s[i]; }

int main(void) {
    crash_install();
    size_t pg = (size_t)getpagesize();
    uint8_t *mem = mmap(NULL, 8 * pg, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (mem == MAP_FAILED) { perror("mmap"); return 2; }
    nvn_dirty_add_range(mem, 8 * pg);
    nvn_pipe_init(done_fn, guest_fn);
    uint64_t a = (uint64_t)(uintptr_t)mem;
    const void *span = nvn_pipe_span(NULL, a, a + 8 * pg);
    EXPECT("1. the pool's range is found", 1, span != NULL);
    EXPECT("1. an unclassified page is not hot", 0, nvn_pipe_hot(span, a, a + pg, 0));
    EXPECT("1. memory outside every pool is untracked", -1, nvn_pipe_hot(NULL, 4096, 8192, 0));

    // 2. read directly by fence 5 (fence 4 completed): a write waits for 5
    atomic_store(&g_done, 4);
    nvn_pipe_direct(span, a, a + pg, 5);
    pthread_t th; pthread_create(&th, NULL, advance, (void *)(uintptr_t)5);
    double ms = timed_write(mem + 100, 7);
    pthread_join(th, NULL);
    EXPECT("2. the write waited for the reading fence (>= 80 ms)", 1, ms >= 80);
    EXPECT("2. the write went through", 7, mem[100]);
    EXPECT("2. the page is hot", 1, nvn_pipe_hot(span, a, a + pg, 0));
    EXPECT("2. one stall counted", 1, stat(1));
    EXPECT("2. a range over it and a cold page is hot", 1, nvn_pipe_hot(span, a, a + 2 * pg, 0));

    // 3. page 1 read by fence 5, which has completed: no wait
    nvn_pipe_direct(span, a + pg, a + 2 * pg, 5);
    ms = timed_write(mem + pg + 8, 9);
    EXPECT("3. a write after the fence completed does not wait (< 50 ms)", 1, ms < 50);
    EXPECT("3. it went through", 9, mem[pg + 8]);
    EXPECT("3. no new stall", 1, stat(1));

    // 4. page 0 (hot) read directly again: protected, cold, a write waits again
    uint32_t ep = nvn_pipe_epoch();
    nvn_pipe_direct(span, a, a + pg, 6);
    EXPECT("4. a hot page read directly is cold again", 0, nvn_pipe_hot(span, a, a + pg, 0));
    EXPECT("4. the epoch changed", 1, nvn_pipe_epoch() != ep);
    pthread_create(&th, NULL, advance, (void *)(uintptr_t)6);
    ms = timed_write(mem + 1, 1);
    pthread_join(th, NULL);
    EXPECT("4. its next write waited for fence 6", 1, ms >= 80);

    // 5. probes. Pages 0 and 1 are hot (written above). Read by nobody directly since. After enough presents both are probed; page 1 is written after its probe
    for (int i = 0; i < 2; i++) nvn_pipe_frame();   // the probe list takes them and protects them (budget 8)
    EXPECT("5. probes made", 1, stat(6) >= 2);
    ms = timed_write(mem + pg + 9, 3);
    EXPECT("5. a write to a probed page does not wait", 1, ms < 50);
    EXPECT("5. probed pages are still hot", 1, nvn_pipe_hot(span, a, a + pg, 0) == 1 && nvn_pipe_hot(span, a + pg, a + 2 * pg, 0) == 1);
    for (int i = 0; i < 4; i++) nvn_pipe_frame();   // page 0: probed at present 1, cold at 5; page 1: probed again at 3, still hot at 6
    EXPECT("5. the page left unwritten turned cold", 0, nvn_pipe_hot(span, a, a + pg, 0));
    EXPECT("5. the page written after its probe stays hot", 1, nvn_pipe_hot(span, a + pg, a + 2 * pg, 0));
    EXPECT("5. demotions counted", 1, stat(7) >= 1);
    atomic_store(&g_done, 100);
    ms = timed_write(mem + 2, 5);
    EXPECT("5. the cooled page is protected: a write faults (and turns it hot)", 1, nvn_pipe_hot(span, a, a + pg, 0));
    for (int i = 0; i < 12; i++) nvn_pipe_frame();
    EXPECT("5. hot again after cooling: hot for good (never probed again)", 1, nvn_pipe_hot(span, a, a + pg, 0));
    EXPECT("5. counted hot for good", 1, stat(12) >= 1);

    // 6. a host write: page 2 read directly by fence 200 (not complete); the host writes it: no wait, classification forgotten
    nvn_pipe_direct(span, a + 2 * pg, a + 3 * pg, 200);
    atomic_store(&g_guest, 0);
    uint64_t host0 = stat(4);
    ms = timed_write(mem + 2 * pg, 4);
    atomic_store(&g_guest, 1);
    EXPECT("6. a host write does not wait", 1, ms < 50);
    EXPECT("6. counted as a host write", host0 + 1, stat(4));
    EXPECT("6. not hot", 0, nvn_pipe_hot(span, a + 2 * pg, a + 3 * pg, 0));
    nvn_pipe_direct(span, a + 2 * pg, a + 3 * pg, 201);   // protected again
    atomic_store(&g_done, 201);
    uint64_t f0 = stat(0); mem[2 * pg + 1] = 1;
    EXPECT("6. the next direct read protected it again (a write faults)", f0 + 1, stat(0));

    // 8. adoption: page 4, never read, taken as hot by a binding that can read a shadow; left unwritten, a probe cools it; a write before that does not wait
    EXPECT("8. without adoption an unread page is not hot", 0, nvn_pipe_hot(span, a + 4 * pg, a + 5 * pg, 0));
    EXPECT("8. adopted: hot", 1, nvn_pipe_hot(span, a + 4 * pg, a + 5 * pg, 1));
    EXPECT("8. counted", 1, stat(11));
    for (int i = 0; i < 8; i++) nvn_pipe_frame();
    EXPECT("8. left unwritten, it cools", 0, nvn_pipe_hot(span, a + 4 * pg, a + 5 * pg, 0));
    EXPECT("8. adopted page 5 written at once: no wait", 1, nvn_pipe_hot(span, a + 5 * pg, a + 6 * pg, 1));
    atomic_store(&g_done, 0); nvn_pipe_frame();   // probed (protected) at this present; nothing reads it directly
    ms = timed_write(mem + 5 * pg, 1);
    EXPECT("8. a write to it does not wait", 1, ms < 50);
    atomic_store(&g_done, 300);

    // 7. the pool goes and another comes over the same memory
    nvn_dirty_remove_range(mem);
    nvn_dirty_add_range(mem, 8 * pg);
    span = nvn_pipe_span(NULL, a, a + 8 * pg);
    EXPECT("7. a new pool over the memory: page 1 not hot", 0, nvn_pipe_hot(span, a + pg, a + 2 * pg, 0));
    f0 = stat(0); mem[pg] = 2;
    EXPECT("7. and not protected", f0, stat(0));

    printf("%s\n", g_fail ? "t_pipe: FAILED" : "t_pipe: all passed");
    return g_fail != 0;
}
