// Write-protect dirty-page tracking for guest memory: pool pages of packaged textures (CPU writes, GPU reads) are set read-only after upload, and as soon as the game writes it faults -> mark dirty, unprotect;
// before use, check the write generation of the covered pages and re-upload if newer than at upload time. NVN semantics: a texture descriptor points to pool memory, and the GPU reads the current content every time
// (measured: the game writes streamed assets into texture storage that is still being sampled, without re-registering).
// Signal handler constraint: the page-fault path uses only atomic operations and mprotect, no allocation, no locks.
#include "nvn_dirty.h"
#include "../../host/dm.h"
#include <stdatomic.h>
#include <pthread.h>
#include <sys/mman.h>
#include <unistd.h>
#include <mach/mach_time.h>
#include <sched.h>

// Order of page state and mprotect: the side changing protection first sets the state to BUSY and sets the final state only after mprotect has landed; other threads wait when they see BUSY.
//   set read-only: NONE -> BUSY -> mprotect(read-only) -> PROT; unprotect: PROT -> BUSY -> mprotect(writable) -> NONE.
// Invariant: a page whose state is NONE is always writable, one whose state is PROT is always read-only. Setting read-only used to be "record PROT, then mprotect"; in between, another thread's unprotect-before-write
// (the movie decoder thread writing a frame into texture storage, a disk read into a guest buffer) could set the state back to NONE, then the mprotect landed => the page read-only with state NONE: a game thread writing it got only
// "re-execute" from the fault handler and spun forever; a host system call reading into it saw NONE in prep_write, skipped, and failed with EFAULT (reproduced by t_dirty_race).
// BUSY lasts at most one mprotect (plus a few atomic writes when setting read-only). The wait is capped at BUSY_WAIT_MS and reports red beyond it: in the fault handler it then returns "not our page" so the crash handler reports truthfully
enum { PG_NONE = 0, PG_PROT = 1, PG_BUSY = 2 };
enum { BUSY_WAIT_MS = 2000 };
// Tracked ranges = the memory pools (registered by MemoryPoolInitialize). After a pool is destroyed its live=0 slot is reused; the signal handler scans without locks.
// The table grows in blocks of 1,024 slots, up to 262,144; a block is never moved or freed, so the signal handler reads it without locks. A pool past the end goes untracked: its textures count
// as dirty and are re-uploaded at every use. The table was a fixed 256 slots (Zelda has about 300 pools at the title), then a fixed 4,096, and Breath of the Wild reaches 4,006 pools in its first
// shrine. The scans only cover slots in use, so the capacity itself costs nothing
enum { BLK_SHIFT = 10, BLK = 1 << BLK_SHIFT, NBLK = 256, MAX_RANGE = BLK * NBLK };
// Ranges are rounded to host pages (16 KB) but guest memory pools are only 4 KB aligned: adjacent pools share their first / last pages, so one address can fall in several registered ranges.
// So: "is this texture tracked" looks for a range that holds its whole span; a fault / host pre-write unprotects and stamps every range covering that page; pool destruction identifies its range by the pool's exact start mem.
// (Previously the first range containing the address was always taken: two SMBW ASTC 6x5 textures whose pool's first page is shared with a small preceding pool were judged untracked and re-uploaded on every use, about 6 MB per frame)
typedef struct { uintptr_t base, end, mem; _Atomic uint8_t *state; _Atomic uint64_t *gen; size_t cap; _Atomic int live; _Atomic uint8_t *pf; _Atomic uint32_t *rf; } range_t;   // pf / rf: frame pipelining (nvn_pipe_*)
static _Atomic(range_t *) g_blk[NBLK];
static inline range_t *rg(int i) { return &atomic_load_explicit(&g_blk[i >> BLK_SHIFT], memory_order_acquire)[i & (BLK - 1)]; }
static _Atomic int g_nr;
static uintptr_t g_pg, g_shift;
static _Atomic uint64_t g_now = 1;
static _Atomic uint64_t g_faults, g_preps;
static _Atomic uint64_t g_adds_total;
static _Atomic int g_live, g_live_peak;   // number of registered pools and peak (for the memory readout line)
void nvn_dirty_stat(int *live, int *peak, int *cap) { *live = atomic_load(&g_live); *peak = atomic_load(&g_live_peak); *cap = MAX_RANGE; }
static _Atomic int g_overflow_logged;
static pthread_mutex_t g_slot_mu = PTHREAD_MUTEX_INITIALIZER;   // Pool creation / destruction (guest threads, possibly concurrent) pick slots under a mutex; the page-fault handling path does not touch it
static _Atomic uint64_t g_mp_calls, g_mp_pages, g_mp_ticks;   // This module's mprotect: call count, pages covered, time spent (mach timebase, safe in the page-fault path too)
static void mp(uintptr_t a, size_t len, int prot) {
    uint64_t t = mach_absolute_time(); mprotect((void *)a, len, prot);
    atomic_fetch_add(&g_mp_ticks, mach_absolute_time() - t); atomic_fetch_add(&g_mp_calls, 1); atomic_fetch_add(&g_mp_pages, len >> g_shift);
}

static mach_timebase_info_data_t g_tb;   // obtained when the first pool is registered (the fault path only multiplies and divides)
static _Atomic int g_busy_red;
// Wait for this page to leave BUSY. Returns 1 = it has left; 0 = waited past the limit (reported red once). Usable in a signal handler: only atomic reads, mach_absolute_time and sched_yield
static int busy_wait(range_t *r, uintptr_t p) {
    uint64_t t0 = 0;
    for (unsigned n = 1; atomic_load(&r->state[p]) == PG_BUSY; n++) {
        if (n & 0x3ff) continue;
        uint64_t now = mach_absolute_time(); if (!t0) t0 = now;
        if ((now - t0) * g_tb.numer / g_tb.denom > (uint64_t)BUSY_WAIT_MS * 1000000ull) {
            if (!atomic_exchange(&g_busy_red, 1)) LOG("[RED] dirty-page tracking: page %p stuck 'busy' for over %d ms (the thread changing its protection has not finished), no longer waiting", (void *)(r->base + (p << g_shift)), BUSY_WAIT_MS);
            return 0; }
        sched_yield();
    }
    return 1;
}
static int live_at(int i) { return atomic_load_explicit(&rg(i)->live, memory_order_acquire); }
// The registered range that holds all of [a, a+len) (used for a texture's tracking / protection / dirty check)
static range_t *find_span(uintptr_t a, size_t len) {
    int n = atomic_load(&g_nr);
    for (int i = 0; i < n; i++) { range_t *r = rg(i); if (live_at(i) && a >= r->base && a + len <= r->end) return r; }
    return NULL;
}
static void unprotect_page(range_t *r, uintptr_t p) {   // The caller has already changed the state from PROT to BUSY
    mp(r->base + (p << g_shift), g_pg, PROT_READ | PROT_WRITE);
    atomic_store(&r->gen[p], atomic_fetch_add(&g_now, 1) + 1);
    atomic_store(&r->state[p], PG_NONE);
}
// Unprotect one page of a range: if protected, unprotect and stamp it; if another thread is changing its protection, wait for it to finish and look again -- if the other side was setting read-only, the page is PROT after the wait and still has to be unprotected
// (an unprotect-before-write never reaches the fault handler, so it must be done here). Returns 1 = this page is managed by this module; 0 = it is not, or the wait on BUSY timed out
static int release_page(range_t *r, uintptr_t p, _Atomic uint64_t *count) {
    for (;;) {
        uint8_t st = PG_PROT;
        if (atomic_compare_exchange_strong(&r->state[p], &st, PG_BUSY)) { unprotect_page(r, p); if (count) atomic_fetch_add(count, 1); return 1; }
        if (st != PG_BUSY) return atomic_load(&r->gen[p]) != 0;   // already NONE: just unprotected by another thread (the fault happened before the unprotect) -> re-execute; pages never protected are not ours
        if (!busy_wait(r, p)) return 0;
    }
}
// DM_NVN_WPROBE: the pages of the game's write faults, for the read-set intersection (hle_nvn.c)
enum { FLOG_N = 65536 }; static uintptr_t g_flog[FLOG_N]; static _Atomic uint64_t g_flog_n; static int g_flog_on;
void nvn_dirty_fault_log(int on) { g_flog_on = on; }
uint64_t nvn_dirty_fault_take(uintptr_t *out, uint64_t from, uint64_t max) { uint64_t n = atomic_load(&g_flog_n), k = 0; if (n - from > FLOG_N) from = n - FLOG_N; for (uint64_t i = from; i < n && k < max; i++) out[k++] = g_flog[i % FLOG_N]; return n; }
static void pipe_fault(range_t *r, uintptr_t p, void *uc); static void pipe_epoch_bump(void);
static int g_pipe_on;
static int on_fault(void *addr, int is_write, void *uc) {
    if (!is_write) return 0;
    if (g_flog_on) { uint64_t i = atomic_fetch_add(&g_flog_n, 1); g_flog[i % FLOG_N] = (uintptr_t)addr; }
    uintptr_t a = (uintptr_t)addr; int ours = 0, n = atomic_load(&g_nr);
    if (g_pipe_on) for (int i = 0; i < n; i++) { range_t *r = rg(i); if (live_at(i) && a >= r->base && a < r->end) pipe_fault(r, (a - r->base) >> g_shift, uc); }   // before any range lets the write through
    for (int i = 0; i < n; i++)   // Every range sharing the page must be released: releasing only one leaves the other range's state at "protected", and later writes no longer fault and are missed
        { range_t *r = rg(i); if (live_at(i) && a >= r->base && a < r->end) ours |= release_page(r, (a - r->base) >> g_shift, &g_faults); }
    return ours;
}
// Unprotect pages p..q of a range with one mprotect per run of protected pages (a host write over a whole texture, e.g. WriteTexels, used to make one system call per 16 KB page:
// Link's Awakening, about 275 a frame). Pages another thread is changing are handled one by one after the run so far is finished, so no BUSY page is held while waiting
static void release_pages(range_t *r, uintptr_t p, uintptr_t q, _Atomic uint64_t *count) {
    uintptr_t run = 0; int open = 0;
    for (uintptr_t i = p; i <= q + 1; i++) {
        uint8_t st = PG_PROT; int took = i <= q && atomic_compare_exchange_strong(&r->state[i], &st, PG_BUSY);
        if (took) { if (!open) { run = i; open = 1; } continue; }
        if (open) {
            mp(r->base + (run << g_shift), (i - run) << g_shift, PROT_READ | PROT_WRITE);
            for (uintptr_t k = run; k < i; k++) { atomic_store(&r->gen[k], atomic_fetch_add(&g_now, 1) + 1); atomic_store(&r->state[k], PG_NONE); }
            if (count) atomic_fetch_add(count, i - run);
            open = 0;
        }
        if (i <= q && st == PG_BUSY) release_page(r, i, count);   // another thread is changing it: wait, then unprotect it if it ended up protected
    }
}
static void prep_write(void *addr, size_t len) {
    uintptr_t a = (uintptr_t)addr, e = a + len; int n = atomic_load(&g_nr);
    if (!len) return;
    for (int i = 0; i < n; i++) {
        range_t *r = rg(i);
        if (!live_at(i) || e <= r->base || a >= r->end) continue;
        uintptr_t lo = a > r->base ? a : r->base, hi = e < r->end ? e : r->end;
        release_pages(r, (lo - r->base) >> g_shift, (hi - 1 - r->base) >> g_shift, &g_preps);
    }
}

void nvn_dirty_add_range(const void *mem, size_t size) {
    static int inited;
    if (!inited) { inited = 1; g_pg = (uintptr_t)getpagesize(); g_shift = __builtin_ctzl(g_pg); mach_timebase_info(&g_tb); dm_fault_hook_register(on_fault); dm_guest_write_prep_register(prep_write); }
    atomic_fetch_add(&g_adds_total, 1);
    pthread_mutex_lock(&g_slot_mu);
    int n = atomic_load(&g_nr);
    int slot = -1;
    for (int i = 0; i < n; i++) if (!live_at(i)) { slot = i; break; }
    if (slot < 0) {
        if (n >= MAX_RANGE) {
            int expected = 0;
            if (atomic_compare_exchange_strong(&g_overflow_logged, &expected, 1)) LOG("[RED] dirty-page tracking ranges are full (%d), pool %p not tracked", MAX_RANGE, mem);
            pthread_mutex_unlock(&g_slot_mu); return;
        }
        slot = n;
        if (!atomic_load_explicit(&g_blk[n >> BLK_SHIFT], memory_order_acquire)) {   // published before g_nr counts the slot (the scans read g_nr first)
            range_t *b = calloc(BLK, sizeof *b); if (!b) die("dirty-page tracking range table allocation failed (block %d)", n >> BLK_SHIFT);
            atomic_store_explicit(&g_blk[n >> BLK_SHIFT], b, memory_order_release);
        }
    }
    { int lv = atomic_fetch_add(&g_live, 1) + 1, pk = atomic_load(&g_live_peak); while (lv > pk && !atomic_compare_exchange_weak(&g_live_peak, &pk, lv)) {} }
    range_t *r = rg(slot);
    uintptr_t base = (uintptr_t)mem & ~(g_pg - 1), end = ((uintptr_t)mem + size + g_pg - 1) & ~(g_pg - 1);
    size_t np = (end - base) >> g_shift;
    _Atomic uint8_t *state = r->state, *pf = r->pf;
    _Atomic uint64_t *gen = r->gen;
    _Atomic uint32_t *rf = r->rf;
    if (r->cap < np) {
        state = calloc(np, 1); gen = calloc(np, sizeof *gen); pf = calloc(np, 1); rf = calloc(np, sizeof *rf);
        if (!state || !gen || !pf || !rf) die("dirty-page table allocation failed (%zu pages)", np);
        // The old arrays are not freed: the signal handler may still have a very brief stale reader; leak = 14 bytes per page.
        r->cap = np;
    } else {
        memset((void *)state, 0, np); memset((void *)gen, 0, np * sizeof *gen); memset((void *)pf, 0, np); memset((void *)rf, 0, np * sizeof *rf);
    }
    r->base = base; r->end = end; r->mem = (uintptr_t)mem; r->state = state; r->gen = gen; r->pf = pf; r->rf = rf;
    if (slot == n) atomic_store(&g_nr, n + 1);
    atomic_store_explicit(&r->live, 1, memory_order_release);
    pipe_epoch_bump();   // a pool over memory another one had: its pages are not classified
    pthread_mutex_unlock(&g_slot_mu);
}
// Pool destruction: first restore still-protected pages to writable (the pool memory may be reused for something else once returned to the game), then mark invalid
void nvn_dirty_remove_range(const void *mem) {
    pthread_mutex_lock(&g_slot_mu);
    range_t *r = NULL; int n = atomic_load(&g_nr);
    for (int i = 0; i < n && !r; i++) if (live_at(i) && rg(i)->mem == (uintptr_t)mem) r = rg(i);   // Match by the pool's exact start: an adjacent pool sharing a page may have the same rounded base
    if (r) { prep_write((void *)r->base, r->end - r->base); atomic_store_explicit(&r->live, 0, memory_order_release); atomic_fetch_sub(&g_live, 1); }
    pthread_mutex_unlock(&g_slot_mu);
}
int nvn_dirty_tracked(const void *addr, size_t len) {
    return find_span((uintptr_t)addr, len) != NULL;
}
// The tracked range holding [addr, addr+len), as a handle a caller keeps (packaged textures: the scan over every range ran twice per texture lookup). NULL = untracked
const void *nvn_dirty_span(const void *addr, size_t len) { return len ? find_span((uintptr_t)addr, len) : NULL; }
// Set read-only: mark the pages BUSY first and mark them PROT only after mprotect has landed (for the order and the invariant see the state notes at the top of the file)
static void protect_pages(range_t *r, uintptr_t p, uintptr_t q);
void nvn_dirty_protect(const void *addr, size_t len) {
    range_t *r = len ? find_span((uintptr_t)addr, len) : NULL;
    if (!r) return;
    uintptr_t a = (uintptr_t)addr; protect_pages(r, (a - r->base) >> g_shift, (a + len - 1 - r->base) >> g_shift);
}
static void protect_pages(range_t *r, uintptr_t p, uintptr_t q) {
    // Consecutive pages are merged into one mprotect (per-page calls reach thousands per frame on the first upload of large textures; character select page startup frame 5: 4888 calls).
    // Pages already PROT / BUSY break the consecutive run: do not protect again, and do not touch pages another thread is changing
    uintptr_t run = 0; int open = 0;
    for (uintptr_t i = p; i <= q + 1; i++) {
        uint8_t st = PG_NONE;
        int took = i <= q && atomic_compare_exchange_strong(&r->state[i], &st, PG_BUSY);
        if (took && !open) { run = i; open = 1; }
        if (!took && open) { mp(r->base + (run << g_shift), (i - run) << g_shift, PROT_READ); for (uintptr_t k = run; k < i; k++) atomic_store(&r->state[k], PG_PROT); open = 0; }
    }
}
uint64_t nvn_dirty_now(void) { return atomic_load(&g_now); }
int nvn_dirty_since_span(const void *span, const void *addr, size_t len, uint64_t stamp) {
    if (!len) return 0;
    range_t *r = (range_t *)span; uintptr_t a0 = (uintptr_t)addr;   // the kept handle still holds the span (a slot reused by another pool over the same memory is as good): no scan
    if (!r || !atomic_load_explicit(&r->live, memory_order_acquire) || a0 < r->base || a0 + len > r->end) r = find_span(a0, len);
    if (!r) return 1;   // When untracked, conservatively treat as dirty: better to upload more than to show stale content
    uintptr_t a = (uintptr_t)addr, p = (a - r->base) >> g_shift, q = (a + len - 1 - r->base) >> g_shift;
    for (uintptr_t i = p; i <= q; i++) if (atomic_load(&r->gen[i]) > stamp) return 1;   // The generation of the last write before upload is <= the stamp; any later write must be > the stamp
    return 0;
}
int nvn_dirty_since(const void *addr, size_t len, uint64_t stamp) { return nvn_dirty_since_span(NULL, addr, len, stamp); }
void nvn_dirty_slot_stats(int *live, int *used_slots, uint64_t *adds_total) {
    int n = atomic_load(&g_nr), active = 0;
    for (int i = 0; i < n; i++) active += live_at(i) != 0;
    *live = active; *used_slots = n; *adds_total = atomic_load(&g_adds_total);
}
void nvn_dirty_stats(uint64_t *faults, uint64_t *preps) { *faults = atomic_load(&g_faults); *preps = atomic_load(&g_preps); }
void nvn_dirty_mp_stats(uint64_t *calls, uint64_t *pages, uint64_t *ns) {
    static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb);
    *calls = atomic_load(&g_mp_calls); *pages = atomic_load(&g_mp_pages); *ns = atomic_load(&g_mp_ticks) * tb.numer / tb.denom;
}
// Diagnostic (DM_NVN_WPROBE, hle_nvn.c): write-protect every tracked range, so the faults until the next call count the pages the CPU writes in a frame
void nvn_dirty_protect_all(void) {
    int n = atomic_load(&g_nr);
    for (int i = 0; i < n; i++) { range_t *r = rg(i); if (live_at(i)) nvn_dirty_protect((const void *)r->base, r->end - r->base); }
}

// ---------- Frame pipelining (DM_NVN_PIPELINE, nvn_mtl.m pipe_*) ----------
// With frame pipelining the CPU prepares frame N+1 while the GPU still runs frame N, so a page of pool memory frame N reads directly (a vertex, index, uniform or storage buffer, a
// copy's source) must not change under it. Each such page is either hot, written by the CPU from frame to frame, and then every binding over it reads a shadow made when the frame is
// replayed (the caller copies), or cold: write-protected, so the first CPU write faults, and the fault waits until the GPU work that read the page directly has completed (rf, the
// low 32 bits of its fence) before the write goes through and the page turns hot. A page is classified (PF_KNOWN) the first time a binding reads it; a host write (a counter report,
// a file read) forgets the classification, so the next direct read protects it again. Hot pages are probed a few a frame: protected again (PF_PROBE) while their bindings still
// read shadows; one not written for PIPE_PROBE_FRAMES presents goes back to cold. Untracked memory (no range) is always shadowed by the caller
enum { PF_KNOWN = 1, PF_HOT = 2, PF_PROBE = 4, PF_LISTED = 8 };
enum { PIPE_RING = 16384, PIPE_PROBE_FRAMES = 4, PIPE_WAIT_MAX_MS = 250 };
static uint64_t (*g_pipe_done)(void);   // the newest completed fence (nvn_mtl.m)
static int (*g_pipe_guest)(void *uc);   // the faulting instruction is guest code (a host write never waits: it may be the thread that completes the fence)
static struct { range_t *_Atomic r; _Atomic uintptr_t p; } g_pipe_ring[PIPE_RING];   // pages turned hot by a fault, for the probe list (the handler cannot allocate)
static _Atomic uint64_t g_pipe_ring_head, g_pipe_ring_tail;
static _Atomic uint32_t g_pipe_epoch;   // bumped whenever a page turns hot or cold (the caller's caches of classified ranges)
uint32_t nvn_pipe_epoch(void) { return atomic_load_explicit(&g_pipe_epoch, memory_order_acquire); }
static _Atomic uint64_t g_ps_faults, g_ps_stalls, g_ps_stall_ns, g_ps_timeouts, g_ps_host, g_ps_hot, g_ps_probes, g_ps_demoted, g_ps_protected, g_ps_reprot;
void nvn_pipe_init(uint64_t (*done)(void), int (*guest_pc)(void *uc)) { g_pipe_done = done; g_pipe_guest = guest_pc; g_pipe_on = 1; }
static uint64_t mono_ns(void) { return mach_absolute_time() * g_tb.numer / g_tb.denom; }
static void pipe_fault(range_t *r, uintptr_t p, void *uc) {
    if (!r->pf || p >= r->cap) return;
    uint8_t f = atomic_load(&r->pf[p]);
    if (!(f & PF_KNOWN)) return;   // not a page a binding read
    atomic_fetch_add(&g_ps_faults, 1);
    if (g_pipe_guest && !g_pipe_guest(uc)) { atomic_fetch_and(&r->pf[p], (uint8_t)~(PF_KNOWN | PF_PROBE)); atomic_fetch_add(&g_ps_host, 1); atomic_fetch_add(&g_pipe_epoch, 1); return; }
    uint32_t need = atomic_load(&r->rf[p]);
    if (need && g_pipe_done && (int32_t)(need - (uint32_t)g_pipe_done()) > 0) {   // a submission still running reads this page directly: the write waits for it
        uint64_t t0 = mono_ns(), lim = t0 + (uint64_t)PIPE_WAIT_MAX_MS * 1000000ull;
        for (unsigned n = 0; (int32_t)(need - (uint32_t)g_pipe_done()) > 0; n++) {
            if (n < 64) { sched_yield(); continue; }
            struct timespec ts = {0, 20000}; nanosleep(&ts, NULL);
            if (mono_ns() > lim) { atomic_fetch_add(&g_ps_timeouts, 1); break; }
        }
        atomic_fetch_add(&g_ps_stalls, 1); atomic_fetch_add(&g_ps_stall_ns, mono_ns() - t0);
    }
    uint8_t old = atomic_fetch_or(&r->pf[p], PF_HOT);
    atomic_fetch_and(&r->pf[p], (uint8_t)~PF_PROBE);
    if (!(old & PF_HOT)) { atomic_fetch_add(&g_ps_hot, 1); atomic_fetch_add(&g_pipe_epoch, 1); }
    if (!(old & PF_LISTED)) {
        uint64_t h = atomic_load(&g_pipe_ring_head);
        if (h - atomic_load(&g_pipe_ring_tail) < PIPE_RING && atomic_compare_exchange_strong(&g_pipe_ring_head, &h, h + 1)) {
            atomic_fetch_or(&r->pf[p], PF_LISTED); atomic_store(&g_pipe_ring[h % PIPE_RING].p, p + 1); atomic_store(&g_pipe_ring[h % PIPE_RING].r, r); }
    }
}
static range_t *pipe_range(const void *span, uint64_t lo, uint64_t hi) {
    range_t *r = (range_t *)span;
    if (!r || !atomic_load_explicit(&r->live, memory_order_acquire) || lo < r->base || hi > r->end) r = find_span((uintptr_t)lo, (size_t)(hi - lo));
    return r && r->pf ? r : NULL;
}
const void *nvn_pipe_span(const void *span, uint64_t lo, uint64_t hi) { return hi > lo ? pipe_range(span, lo, hi) : NULL; }
// 1 when a page of [lo, hi) is hot (the binding reads a shadow), 0 when none is, -1 when the memory is not tracked
int nvn_pipe_hot(const void *span, uint64_t lo, uint64_t hi) {
    if (hi <= lo) return 0;
    range_t *r = pipe_range(span, lo, hi); if (!r) return -1;
    for (uintptr_t i = (lo - r->base) >> g_shift, q = (hi - 1 - r->base) >> g_shift; i <= q; i++) if (atomic_load_explicit(&r->pf[i], memory_order_relaxed) & PF_HOT) return 1;
    return 0;
}
// [lo, hi) is read directly by the submission with this fence: every page of it protected (a hot one turns cold again), stamped with the fence
void nvn_pipe_direct(const void *span, uint64_t lo, uint64_t hi, uint32_t fence) {
    if (hi <= lo) return;
    range_t *r = pipe_range(span, lo, hi); if (!r) return;
    uintptr_t p = (lo - r->base) >> g_shift, q = (hi - 1 - r->base) >> g_shift, run = 0; int open = 0;
    for (uintptr_t i = p; i <= q + 1; i++) {
        int need = 0;
        if (i <= q) { uint8_t f = atomic_load_explicit(&r->pf[i], memory_order_relaxed); atomic_store_explicit(&r->rf[i], fence, memory_order_relaxed);
            if ((f & (PF_KNOWN | PF_HOT)) != PF_KNOWN) { need = 1; if (f & PF_HOT) { atomic_fetch_add(&g_ps_reprot, 1); atomic_fetch_add(&g_pipe_epoch, 1); } atomic_fetch_and(&r->pf[i], (uint8_t)~(PF_HOT | PF_PROBE)); atomic_fetch_or(&r->pf[i], PF_KNOWN); } }
        if (need && !open) { run = i; open = 1; }
        if (!need && open) { protect_pages(r, run, i - 1); atomic_fetch_add(&g_ps_protected, i - run); open = 0; }
    }
    atomic_thread_fence(memory_order_release);
}
// At each present: pages turned hot join the probe list; a few are protected again, and those not written for PIPE_PROBE_FRAMES presents since turn cold
typedef struct { range_t *r; uintptr_t p; uint64_t at; } pipe_ent;
static pipe_ent *g_pl; static size_t g_npl, g_capl, g_plcur; static uint64_t g_pl_frame;
static pthread_mutex_t g_pl_mu = PTHREAD_MUTEX_INITIALIZER;
void nvn_pipe_frame(void) {
    pthread_mutex_lock(&g_pl_mu);
    g_pl_frame++;
    for (uint64_t t = atomic_load(&g_pipe_ring_tail), h = atomic_load(&g_pipe_ring_head); t < h; t++) {
        range_t *r = NULL; uintptr_t p1 = 0;
        for (int k = 0; k < 1000 && !((r = atomic_load(&g_pipe_ring[t % PIPE_RING].r)) && (p1 = atomic_load(&g_pipe_ring[t % PIPE_RING].p))); k++) sched_yield();   // a writer between its claim and its store
        atomic_store(&g_pipe_ring[t % PIPE_RING].r, NULL); atomic_store(&g_pipe_ring[t % PIPE_RING].p, 0); atomic_store(&g_pipe_ring_tail, t + 1);
        if (!r || !p1) continue;
        if (g_npl == g_capl) { g_capl = g_capl ? 2 * g_capl : 1024; g_pl = realloc(g_pl, g_capl * sizeof *g_pl); }
        g_pl[g_npl++] = (pipe_ent){r, p1 - 1, 0};
    }
    size_t budget = g_npl / 16 + 8;
    for (size_t k = 0, n = g_npl; k < n && g_npl; k++) {
        if (g_plcur >= g_npl) g_plcur = 0;
        pipe_ent *e = &g_pl[g_plcur];
        uint8_t f = e->p < e->r->cap && atomic_load(&e->r->live) ? atomic_load(&e->r->pf[e->p]) : 0;
        if (!(f & PF_HOT)) { if (e->p < e->r->cap) atomic_fetch_and(&e->r->pf[e->p], (uint8_t)~PF_LISTED); g_pl[g_plcur] = g_pl[--g_npl]; continue; }   // turned cold by a direct read, or the pool went
        if (f & PF_PROBE) {
            if (g_pl_frame - e->at >= PIPE_PROBE_FRAMES) { atomic_fetch_and(&e->r->pf[e->p], (uint8_t)~(PF_HOT | PF_PROBE | PF_LISTED)); atomic_fetch_add(&g_ps_demoted, 1); atomic_fetch_add(&g_pipe_epoch, 1); g_pl[g_plcur] = g_pl[--g_npl]; continue; }
        } else if (budget) {
            budget--; atomic_fetch_or(&e->r->pf[e->p], PF_PROBE); protect_pages(e->r, e->p, e->p); e->at = g_pl_frame; atomic_fetch_add(&g_ps_probes, 1);
        } else break;
        g_plcur++;
    }
    pthread_mutex_unlock(&g_pl_mu);
}
void nvn_pipe_stats(uint64_t s[12]) {
    s[0] = g_ps_faults; s[1] = g_ps_stalls; s[2] = g_ps_stall_ns; s[3] = g_ps_timeouts; s[4] = g_ps_host; s[5] = g_ps_hot; s[6] = g_ps_probes; s[7] = g_ps_demoted; s[8] = g_ps_protected; s[9] = g_ps_reprot;
    pthread_mutex_lock(&g_pl_mu); s[10] = g_npl; pthread_mutex_unlock(&g_pl_mu); s[11] = 0;
}
static void pipe_epoch_bump(void) { atomic_fetch_add(&g_pipe_epoch, 1); }
