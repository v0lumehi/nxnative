// GPU clock probe for the iPhone (measurement app, its own bundle ID): does a sustained 60 Hz load keep the GPU clock, or do idle gaps and serialised passes,
// the host's pattern, make the governor pick a lower one? Metal 4 like the host. Each frame: NH heavy passes (one vertex-heavy draw whose triangles are culled after
// the vertex stage, one fragment-heavy full-screen triangle into a 1024x1024 target) and NT tiny passes (64x64, one trivial draw), in NSEG command buffers, then
// a small present pass into the drawable. Work is sized at launch to TV ms of vertex and TF ms of fragment work per frame at the clock a short full load reaches.
// Variants (the order is the launch argument -order, each runs -secs seconds, -rest seconds of idle between them):
//   A  continuous: no barriers between passes (vertex of one pass may run under the fragment of the one before), all segments committed at once, two frames in flight
//   B  host pattern: full barriers around every pass (vertex -> fragment serialised, as the host's default), each segment waited for, then -gap ms of CPU before the next
//   C  B's full barriers without the gaps (two frames in flight): serialisation alone
//   D  A's free overlap with B's gaps: gaps alone
// Every -every seconds Documents/clock.txt gets a line: frames per second, GPU busy per frame (union of the command buffers' GPU intervals), GPU utilisation of the window,
// idle share inside the frames' GPU span, and the clock proxies: an ALU probe pass (fixed fragment loop, committed right behind a frame) and a tiny pass, in us and
// relative to the fastest seen at launch (1.00 = the clock of the launch's full load), with the thermal state.
#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#include <pthread.h>
#include <stdatomic.h>
#include <mach/mach_time.h>
#include <os/workgroup.h>
#import <AudioToolbox/AudioWorkInterval.h>
enum { NH = 20, NT = 100, NSEG_MAX = 16, NAL = 3 };
typedef struct { int vk, fk, pk, pad; } P;
static id<MTLDevice> dev; static id<MTL4CommandQueue> q; static id<MTL4CommandAllocator> al[NAL], alp; static id<MTLSharedEvent> ev; static uint64_t evv;
static id<MTLRenderPipelineState> psV, psF, psT, psP, psD; static id<MTLTexture> tg[NH], tt, tp; static id<MTL4ArgumentTable> at; static id<MTLBuffer> pb;
static CAMetalLayer *layer; static FILE *out;
static int VN = 200000, NSEG = 6; static double TV = 4, TF = 6, GAP = 0.9;
// GPU intervals from commit feedback (seconds, CACurrentMediaTime base): GPU busy and utilisation per window
typedef struct { double s, e; } iv_t;
static iv_t ivs[1 << 16]; static int niv; static pthread_mutex_t ivmu = PTHREAD_MUTEX_INITIALIZER;
static void commit1(id<MTL4CommandBuffer> cb) {
    MTL4CommitOptions *o = [MTL4CommitOptions new];
    [o addFeedbackHandler:^(id<MTL4CommitFeedback> f) { if (f.error) { fprintf(out, "command buffer error: %s\n", f.error.description.UTF8String); fflush(out); }
        pthread_mutex_lock(&ivmu); if (niv < (1 << 16)) ivs[niv++] = (iv_t){f.GPUStartTime, f.GPUEndTime}; pthread_mutex_unlock(&ivmu); }];
    id<MTL4CommandBuffer> one[1] = {cb}; [q commit:one count:1 options:o];
}
static uint64_t signal_now(void) { [q signalEvent:ev value:++evv]; return evv; }
static void wait_ev(uint64_t v) { [ev waitUntilSignaledValue:v timeoutMS:20000]; }
static id<MTLRenderPipelineState> mk(id<MTLLibrary> l, NSString *v, NSString *f, MTLPixelFormat pf) {
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new]; d.vertexFunction = [l newFunctionWithName:v]; d.fragmentFunction = [l newFunctionWithName:f];
    d.colorAttachments[0].pixelFormat = pf; NSError *e = nil; id<MTLRenderPipelineState> p = [dev newRenderPipelineStateWithDescriptor:d error:&e];
    if (!p) { fprintf(out, "pipeline %s/%s: %s\n", v.UTF8String, f.UTF8String, e.localizedDescription.UTF8String); fflush(out); } return p; }
// Pass timestamps (as the host's GPUPROF: after the vertex stage at the start, after the fragment stage at the end), written on probe frames only.
// Slots: heavy pass h -> h, tiny pass j -> NH + j, ALU probe -> PI_ALU, tiny probe -> PI_TINY
enum { PI_ALU = NH + NT, PI_TINY = NH + NT + 1, PI_N = NH + NT + 2 };
static id<MTL4CounterHeap> heap; static double tick_ns;
// One pass. full: the host's default barriers around it. what: 1 vertex-heavy draw, 2 fragment-heavy draw, 4 tiny (trivial draw), 8 ALU probe, 16 present; ts: slot or -1
static void pass(id<MTL4CommandBuffer> cb, id<MTLTexture> t, int what, int full, int ts) {
    MTL4RenderPassDescriptor *rp = [MTL4RenderPassDescriptor new]; rp.colorAttachments[0].texture = t; rp.colorAttachments[0].loadAction = (what & 3) ? MTLLoadActionLoad : MTLLoadActionClear;   // heavy passes load and store (memory traffic, as the game's passes) rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTL4RenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
    if (full) [e barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice];
    if (ts >= 0) [e writeTimestampWithGranularity:MTL4TimestampGranularityRelaxed afterStage:MTLRenderStageVertex intoHeap:heap atIndex:2 * ts];
    [e setArgumentTable:at atStages:MTLRenderStageVertex | MTLRenderStageFragment];
    if (what & 1) { [e setRenderPipelineState:psV]; [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:(NSUInteger)VN]; }
    if (what & 2) { [e setRenderPipelineState:psF]; [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; }
    if (what & 4) { [e setRenderPipelineState:psT]; [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; }
    if (what & 8) { [e setRenderPipelineState:psP]; [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; }
    if (what & 16) { [e setRenderPipelineState:psD]; [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; }
    if (ts >= 0) [e writeTimestampWithGranularity:MTL4TimestampGranularityRelaxed afterStage:MTLRenderStageFragment intoHeap:heap atIndex:2 * ts + 1];
    if (full) [e barrierAfterStages:MTLStageAll beforeQueueStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice];
    [e endEncoding];
}
// The two probes: with full barriers on both sides, so nothing before or after runs under them
static void probes(id<MTL4CommandBuffer> cb, int ts) { pass(cb, tp, 8, 1, ts ? PI_ALU : -1); pass(cb, tt, 4, 1, ts ? PI_TINY : -1); }
// One frame. full: barriers around every pass; gaps: each segment waited for, then GAP ms on the CPU; what: 3 both, 1 vertex only, 2 fragment only; present: into a drawable;
// probe: timestamps on every pass and the probes after the frame's work. Returns the event value that marks the frame's end.
static uint64_t frame(int full, int gaps, int what, int present, int probe) {
    static int ai; id<MTL4CommandAllocator> a = al[ai++ % NAL]; [a reset];
    if (probe) [heap invalidateCounterRange:NSMakeRange(0, 2 * PI_N)];
    id<CAMetalDrawable> dr = present ? [layer nextDrawable] : nil; uint64_t v = 0;
    for (int s = 0; s < NSEG; s++) {
        id<MTL4CommandBuffer> cb = [dev newCommandBuffer]; [cb beginCommandBufferWithAllocator:a];
        for (int h = s * NH / NSEG; h < (s + 1) * NH / NSEG; h++) { pass(cb, tg[h], what, full, probe ? h : -1); for (int k = 0; k < NT / NH; k++) pass(cb, tt, 4, full, probe ? NH + h * (NT / NH) + k : -1); }
        int last = s == NSEG - 1;
        if (last && probe) probes(cb, 1);   // right behind the frame's work, before any gap: the clock the frame ran at
        if (last && dr) { [q waitForDrawable:dr]; pass(cb, dr.texture, 16, full, -1); }
        [cb endCommandBuffer]; commit1(cb);
        if (last && dr) { [q signalDrawable:dr]; [dr presentAfterMinimumDuration:1.0 / 60]; }
        v = signal_now();
        if (gaps && !last) { wait_ev(v); usleep((useconds_t)(GAP * 1000)); }
    }
    return v;
}
static int cmpd(const void *a, const void *b) { double x = *(const double *)a, y = *(const double *)b; return x < y ? -1 : x > y; }
static int cmp_iv(const void *a, const void *b) { double x = ((const iv_t *)a)->s, y = ((const iv_t *)b)->s; return x < y ? -1 : x > y; }
static double union_of(iv_t *v, int n, double *span) { qsort(v, n, sizeof *v, cmp_iv); double u = 0, cs = -1, ce = -1, s0 = n ? v[0].s : 0, s1 = 0;
    for (int i = 0; i < n; i++) { if (v[i].e > s1) s1 = v[i].e; if (v[i].s > ce) { if (ce > cs) u += ce - cs; cs = v[i].s; ce = v[i].e; } else if (v[i].e > ce) ce = v[i].e; }
    if (ce > cs) u += ce - cs; if (span) *span = s1 - s0; return u; }
// Reads a probe frame's timestamps (the frame has completed): probes in us, medians of the in-frame tiny and heavy passes in us, the frame's pass span and pass-busy share
typedef struct { double alu, tiny, ftiny, fheavy, span_ms, busy_ms; } pr_t;
static pr_t read_probe(int whole) {
    pr_t r = {0}; NSData *d = [heap resolveCounterRange:NSMakeRange(0, 2 * PI_N)]; const uint64_t *t = d.bytes; if (!t) return r;
    #define US(i) ((t[2 * (i)] && t[2 * (i) + 1] > t[2 * (i)]) ? (t[2 * (i) + 1] - t[2 * (i)]) * tick_ns / 1e3 : -1)
    r.alu = US(PI_ALU); r.tiny = US(PI_TINY);
    if (whole) { double a[NT]; int n = 0; for (int j = 0; j < NT; j++) { double u = US(NH + j); if (u > 0) a[n++] = u; } qsort(a, n, sizeof *a, cmpd); r.ftiny = n ? a[n / 2] : 0;
        double b[NH]; n = 0; for (int h = 0; h < NH; h++) { double u = US(h); if (u > 0) b[n++] = u; } qsort(b, n, sizeof *b, cmpd); r.fheavy = n ? b[n / 2] : 0;
        iv_t v[NH + NT]; n = 0; for (int i = 0; i < NH + NT; i++) if (t[2 * i] && t[2 * i + 1] > t[2 * i]) v[n++] = (iv_t){t[2 * i] * tick_ns / 1e6, t[2 * i + 1] * tick_ns / 1e6};
        double span; r.busy_ms = union_of(v, n, &span); r.span_ms = span; }
    #undef US
    return r;
}
static double frame_ms(int full, int what) { pthread_mutex_lock(&ivmu); niv = 0; pthread_mutex_unlock(&ivmu); wait_ev(frame(full, 0, what, 0, 0));
    for (int w = 0; w < 200; w++) { pthread_mutex_lock(&ivmu); int n = niv; pthread_mutex_unlock(&ivmu); if (n >= NSEG) break; usleep(500); }
    pthread_mutex_lock(&ivmu); double sp; union_of(ivs, niv, &sp); niv = 0; pthread_mutex_unlock(&ivmu); return sp * 1e3; }
static double med_ms(int full, int what, int n) { double v[32]; for (int i = 0; i < n; i++) v[i] = frame_ms(full, what); qsort(v, n, sizeof *v, cmpd); return v[n / 2]; }
static double ref_alu = 1e9, ref_tiny = 1e9;
static pr_t probe_once(void) { [heap invalidateCounterRange:NSMakeRange(0, 2 * PI_N)]; [alp reset]; id<MTL4CommandBuffer> c = [dev newCommandBuffer]; [c beginCommandBufferWithAllocator:alp];
    probes(c, 1); [c endCommandBuffer]; commit1(c); wait_ev(signal_now()); return read_probe(0); }
static const char *thermal(void) { switch (NSProcessInfo.processInfo.thermalState) { case NSProcessInfoThermalStateNominal: return "nominal"; case NSProcessInfoThermalStateFair: return "fair";
    case NSProcessInfoThermalStateSerious: return "serious"; case NSProcessInfoThermalStateCritical: return "critical"; } return "?"; }
// Keepalive (diagnostic): a second queue that keeps two single-threadgroup ALU dispatches of about 1 ms in flight all the time
static id<MTL4CommandQueue> kq; static id<MTLComputePipelineState> csK; static id<MTL4ArgumentTable> kat; static id<MTLSharedEvent> kev; static volatile int keep_on; static _Atomic long keep_n; static double keep_busy;
static pthread_t keep_th;
static void *keep_loop(void *u) { (void)u; id<MTL4CommandAllocator> ka[2] = {[dev newCommandAllocator], [dev newCommandAllocator]}; uint64_t kv[2] = {0}, kvv = 0;
    for (long i = 0; keep_on; i++) { int k = (int)(i & 1); if (kv[k]) [kev waitUntilSignaledValue:kv[k] timeoutMS:20000]; [ka[k] reset];
        id<MTL4CommandBuffer> cb = [dev newCommandBuffer]; [cb beginCommandBufferWithAllocator:ka[k]]; id<MTL4ComputeCommandEncoder> ce = [cb computeCommandEncoder];
        [ce setComputePipelineState:csK]; [ce setArgumentTable:kat]; [ce dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)]; [ce endEncoding]; [cb endCommandBuffer];
        MTL4CommitOptions *o = [MTL4CommitOptions new]; [o addFeedbackHandler:^(id<MTL4CommitFeedback> f) { keep_busy += f.GPUEndTime - f.GPUStartTime; atomic_fetch_add(&keep_n, 1); }];
        id<MTL4CommandBuffer> one[1] = {cb}; [kq commit:one count:1 options:o]; [kq signalEvent:kev value:++kvv]; kv[k] = kvv; }
    [kev waitUntilSignaledValue:kvv timeoutMS:20000]; return NULL; }
static int VN0, FK0; static double serial_ms = 10;
// A token: a variant letter (A-D), then optionally the full-clock work per frame in ms (A12: 12 ms), 'w' (the run thread in an Audio Workgroup interval per frame), 'k' (keepalive queue)
static void variant(const char *tok, double secs, double every) {
    char c = tok[0]; double work = atof(tok + 1); int wg = strchr(tok, 'w') != NULL, keep = strchr(tok, 'k') != NULL;
    int full = c == 'B' || c == 'C', gaps = c == 'B' || c == 'D', inflight = gaps ? 1 : 2;
    P *p = (P *)pb.contents; VN = VN0; p->fk = FK0; if (work > 0) { VN = (int)(VN0 * work / serial_ms); p->fk = (int)(FK0 * work / serial_ms + 0.5); if (p->fk < 1) p->fk = 1; }
    const char *desc = c == 'A' ? "continuous, no barriers, two frames in flight" : c == 'B' ? "host pattern: full barriers, each segment waited for plus the gap" :
                       c == 'C' ? "full barriers, no gaps, two frames in flight" : "no barriers, each segment waited for plus the gap";
    fprintf(out, "== %s: %s (%d segments, gap %.2f ms), work %s (VN %d FK %d)%s%s, %.0f s\n", tok, desc, NSEG, GAP, work > 0 ? tok + 1 : "base", VN, p->fk,
            wg ? ", Audio Workgroup interval per frame" : "", keep ? ", keepalive queue" : "", secs); fflush(out);
    os_workgroup_t wgp = NULL; os_workgroup_join_token_s wtok; uint64_t per_ticks = 0;
    if (wg) { wgp = AudioWorkIntervalCreate("clockprobe", OS_CLOCK_MACH_ABSOLUTE_TIME, NULL); int r = wgp ? os_workgroup_join(wgp, &wtok) : -1;
        mach_timebase_info_data_t tb; mach_timebase_info(&tb); per_ticks = (uint64_t)(1e9 / 60 * tb.denom / tb.numer); fprintf(out, "  workgroup %p join %d\n", (__bridge void *)wgp, r); fflush(out); if (r) wg = 0; }
    if (keep) { keep_on = 1; keep_n = 0; keep_busy = 0; pthread_create(&keep_th, NULL, keep_loop, NULL); }
    pthread_mutex_lock(&ivmu); niv = 0; pthread_mutex_unlock(&ivmu);
    double start = CACurrentMediaTime(), next = start, last = start, sum_rel = 0; int n = 0, nwin = 0; uint64_t fv[4] = {0}; long fi = 0, kn0 = 0; double kb0 = 0;
    while (CACurrentMediaTime() - start < secs) {
        double now = CACurrentMediaTime(); int pr = now - last >= every;
        if (wg) { uint64_t t = mach_absolute_time(); os_workgroup_interval_start((os_workgroup_interval_t)wgp, t, t + per_ticks, NULL); }
        if (fi >= inflight) wait_ev(fv[(fi - inflight) & 3]);
        fv[fi & 3] = frame(full, gaps, 3, 1, pr); fi++; n++;
        if (wg) os_workgroup_interval_finish((os_workgroup_interval_t)wgp, NULL);
        if (pr) {
            wait_ev(fv[(fi - 1) & 3]); usleep(2000);   // the probe frame's timestamps and the window's last feedback
            pr_t r = read_probe(1); now = CACurrentMediaTime(); double win = now - last;
            pthread_mutex_lock(&ivmu); double u = union_of(ivs, niv, NULL); niv = 0; pthread_mutex_unlock(&ivmu);
            double rel = r.alu > 0 ? ref_alu / r.alu : 0; sum_rel += rel; nwin++;
            char ks[96] = ""; if (keep) { long kn = atomic_load(&keep_n); snprintf(ks, sizeof ks, " | keepalive %ld dispatches, %.2f ms each", kn - kn0, kn > kn0 ? (keep_busy - kb0) * 1e3 / (kn - kn0) : 0); kn0 = kn; kb0 = keep_busy; }
            fprintf(out, "%s t %5.1f s  %5.1f fps  GPU busy/frame %6.2f ms  util %3.0f%%  | probe ALU %6.1f us (clock %.2f)  tiny %5.1f us (%.2f) | in frame: tiny median %5.1f us, heavy median %6.1f us, pass span %5.2f ms, idle in it %3.0f%%%s | thermal %s\n",
                    tok, now - start, n / win, n ? u * 1e3 / n : 0, 100 * u / win, r.alu, rel, r.tiny, r.tiny > 0 ? ref_tiny / r.tiny : 0, r.ftiny, r.fheavy, r.span_ms,
                    r.span_ms > 0 ? 100 * (1 - r.busy_ms / r.span_ms) : 0, ks, thermal()); fflush(out);
            last = now; n = 0;
        }
        next += 1.0 / 60; now = CACurrentMediaTime(); if (next > now) usleep((useconds_t)((next - now) * 1e6)); else next = now;
    }
    for (long k = fi - inflight; k < fi; k++) if (k >= 0) wait_ev(fv[k & 3]);
    if (keep) { keep_on = 0; pthread_join(keep_th, NULL); }
    if (wg) os_workgroup_leave(wgp, &wtok);
    fprintf(out, "== %s mean relative clock %.2f over %d windows\n", tok, nwin ? sum_rel / nwin : 0, nwin); fflush(out);
}
// -cpu n: n threads that spin for -duty of every 1/60 s (the game's CPU load shares the SoC's power budget)
static double DUTY = 0.5; static volatile int cpu_stop;
static void *cpu_load(void *u) { (void)u; volatile double x = 1; while (!cpu_stop) { double t0 = CACurrentMediaTime(); while (CACurrentMediaTime() - t0 < DUTY / 60) for (int i = 0; i < 1000; i++) x = x * 1.0000001 + 1e-9;
    double r = (1 - DUTY) / 60; if (r > 0) usleep((useconds_t)(r * 1e6)); } return NULL; }
static NSString *arg(NSString *k, NSString *d) { NSString *v = [NSUserDefaults.standardUserDefaults stringForKey:k]; return v ? v : d; }
// -latency 1: how long the GPU idles at a CPU wait on GPU completion (the host's sync points): one fragment pass per command buffer, the CPU waits for it
// and commits the next at once. Methods: 0 the shared event's waitUntilSignaledValue, 1 spinning on its signaledValue, 2 the commit feedback handler and a condition variable.
// Per method: the GPU idle between consecutive command buffers and the CPU wake after the GPU end (medians and p90 in us)
static pthread_mutex_t lmu = PTHREAD_MUTEX_INITIALIZER; static pthread_cond_t lcv = PTHREAD_COND_INITIALIZER; static long ldone;
static void latency_run(void) {
    enum { N = 400 }; static double gs[N], ge[N], wk[N]; NSError *e = nil; (void)e;
    for (int m = 0; m < 3; m++) for (int rep = 0; rep < 2; rep++) {
        for (int i = 0; i < N; i++) {
            static int ai; id<MTL4CommandAllocator> a = al[ai++ % NAL]; [a reset]; id<MTL4CommandBuffer> cb = [dev newCommandBuffer]; [cb beginCommandBufferWithAllocator:a];
            pass(cb, tg[i % NH], 2, 1, -1); [cb endCommandBuffer];
            MTL4CommitOptions *o = [MTL4CommitOptions new]; long me = i + 1 + (long)(m * 2 + rep) * N;
            [o addFeedbackHandler:^(id<MTL4CommitFeedback> f) { gs[i] = f.GPUStartTime; ge[i] = f.GPUEndTime; pthread_mutex_lock(&lmu); ldone = me; pthread_cond_broadcast(&lcv); pthread_mutex_unlock(&lmu); }];
            id<MTL4CommandBuffer> one[1] = {cb}; [q commit:one count:1 options:o]; uint64_t v = signal_now();
            if (m == 0) wait_ev(v); else if (m == 1) { while (ev.signaledValue < v) ; } else { pthread_mutex_lock(&lmu); while (ldone < me) pthread_cond_wait(&lcv, &lmu); pthread_mutex_unlock(&lmu); }
            wk[i] = CACurrentMediaTime();
        }
        wait_ev(signal_now()); usleep(20000);
        double idle[N], wake[N]; int n = 0; for (int i = 1; i < N; i++) if (ge[i - 1] > 0 && gs[i] > 0) { idle[n] = (gs[i] - ge[i - 1]) * 1e6; wake[n] = (wk[i - 1] - ge[i - 1]) * 1e6; n++; }
        qsort(idle, n, sizeof *idle, cmpd); qsort(wake, n, sizeof *wake, cmpd); double busy = 0; for (int i = 0; i < N; i++) busy += (ge[i] - gs[i]) * 1e6; busy /= (double)N;
        const char *mn[3] = {"waitUntilSignaledValue", "spin on signaledValue", "feedback handler + condvar"};
        fprintf(out, "latency %-27s rep %d: GPU idle between command buffers p50 %6.1f us p90 %6.1f us; CPU wake after GPU end p50 %6.1f us p90 %6.1f us; busy per buffer %.1f us; thermal %s\n",
                mn[m], rep, idle[n / 2], idle[n * 9 / 10], wake[n / 2], wake[n * 9 / 10], busy, thermal()); fflush(out);
    }
}
void overlap_run(FILE *out);   // overlap.m: -overlap 1 runs that micro-test instead
static void run(void) {
    if (arg(@"overlap", @"0").intValue) { overlap_run(out); fprintf(out, "done\n"); fflush(out); return; }
    dev = MTLCreateSystemDefaultDevice(); NSError *e = nil; q = [dev newMTL4CommandQueue]; for (int i = 0; i < NAL; i++) al[i] = [dev newCommandAllocator]; alp = [dev newCommandAllocator]; ev = [dev newSharedEvent];
    NSString *order = arg(@"order", @"AB"); double secs = arg(@"secs", @"300").doubleValue, rest = arg(@"rest", @"60").doubleValue, every = arg(@"every", @"5").doubleValue;
    TV = arg(@"tv", @"4").doubleValue; TF = arg(@"tf", @"6").doubleValue; GAP = arg(@"gap", @"0.9").doubleValue; NSEG = arg(@"nseg", @"6").intValue; if (NSEG < 1) NSEG = 1; if (NSEG > NSEG_MAX) NSEG = NSEG_MAX;
    id<MTLLibrary> l = [dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\nstruct O { float4 p [[position]]; float4 c; };\nstruct P { int vk, fk, pk, pad; };\n"
        "vertex O vheavy(uint v [[vertex_id]], constant P &p [[buffer(0)]]) { float x = float(v) * 1e-6; for (int i = 0; i < p.vk; i++) x = fma(x, 1.0001, sin(x) * 0.5); O o; o.p = float4(4.0 + x * 1e-9, 4.0, 0.5, 1.0); o.c = float4(x); return o; }\n"
        "vertex O vfull(uint v [[vertex_id]]) { O o; float2 t = float2((v << 1) & 2, v & 2); o.p = float4(t * 2.0 - 1.0, 0.5, 1.0); o.c = float4(t, 0, 1); return o; }\n"
        "fragment float4 fnone(O i [[stage_in]]) { return i.c; }\n"
        "fragment float4 fheavy(O i [[stage_in]], constant P &p [[buffer(0)]]) { float x = i.c.x + i.p.x * 1e-4; for (int k = 0; k < p.fk; k++) x = fma(x, 1.0001, sin(x) * 0.5); return float4(x, i.c.y, 0, 1); }\n"
        "fragment float4 fprobe(O i [[stage_in]], constant P &p [[buffer(0)]]) { float x = i.c.x + i.p.x * 1e-4; for (int k = 0; k < p.pk; k++) x = fma(x, 1.0001, sin(x) * 0.5); return float4(x, i.c.y, 0, 1); }\n"
        "kernel void kalive(device float *o [[buffer(0)]], constant P &p [[buffer(1)]], uint t [[thread_position_in_grid]]) { float x = float(t); for (int k = 0; k < p.pad; k++) x = fma(x, 1.0001, sin(x) * 0.5); o[t] = x; }\n"
        options:nil error:&e];
    if (!l) { fprintf(out, "library: %s\n", e.localizedDescription.UTF8String); fflush(out); return; }
    psV = mk(l, @"vheavy", @"fnone", MTLPixelFormatRGBA8Unorm); psF = mk(l, @"vfull", @"fheavy", MTLPixelFormatRGBA8Unorm); psT = mk(l, @"vfull", @"fnone", MTLPixelFormatRGBA8Unorm);
    psP = mk(l, @"vfull", @"fprobe", MTLPixelFormatRGBA8Unorm); psD = mk(l, @"vfull", @"fnone", layer.pixelFormat);
    MTLResidencySetDescriptor *rd = [MTLResidencySetDescriptor new]; id<MTLResidencySet> rs = [dev newResidencySetWithDescriptor:rd error:&e];
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:1024 height:1024 mipmapped:NO]; d.usage = MTLTextureUsageRenderTarget; d.storageMode = MTLStorageModePrivate;
    for (int i = 0; i < NH; i++) { tg[i] = [dev newTextureWithDescriptor:d]; [rs addAllocation:tg[i]]; }
    d.width = d.height = 64; tt = [dev newTextureWithDescriptor:d]; [rs addAllocation:tt]; d.width = d.height = 128; tp = [dev newTextureWithDescriptor:d]; [rs addAllocation:tp];
    pb = [dev newBufferWithLength:1024 options:MTLResourceStorageModeShared]; [rs addAllocation:pb]; [rs commit]; [q addResidencySet:rs]; [q addResidencySet:layer.residencySet];
    MTL4ArgumentTableDescriptor *ad = [MTL4ArgumentTableDescriptor new]; ad.maxBufferBindCount = 2; at = [dev newArgumentTableWithDescriptor:ad error:&e]; [at setAddress:pb.gpuAddress atIndex:0];
    kat = [dev newArgumentTableWithDescriptor:ad error:&e]; [kat setAddress:pb.gpuAddress + 128 atIndex:0]; [kat setAddress:pb.gpuAddress atIndex:1];
    csK = [dev newComputePipelineStateWithFunction:[l newFunctionWithName:@"kalive"] error:&e]; if (!csK) { fprintf(out, "kalive: %s\n", e.localizedDescription.UTF8String); fflush(out); }
    kq = [dev newMTL4CommandQueue]; [kq addResidencySet:rs]; kev = [dev newSharedEvent];
    MTL4CounterHeapDescriptor *hd = [MTL4CounterHeapDescriptor new]; hd.type = MTL4CounterHeapTypeTimestamp; hd.count = 2 * PI_N; heap = [dev newCounterHeapWithDescriptor:hd error:&e];
    if (!heap) { fprintf(out, "no counter heap: %s\n", e.localizedDescription.UTF8String); fflush(out); return; } tick_ns = 1e9 / (double)[dev queryTimestampFrequency];
    P *p = (P *)pb.contents; *p = (P){64, 64, 2000, 0};
    int ncpu = arg(@"cpu", @"0").intValue; DUTY = arg(@"duty", @"0.5").doubleValue; double cool = arg(@"cool", @"600").doubleValue;
    for (double w = 0; NSProcessInfo.processInfo.thermalState != NSProcessInfoThermalStateNominal && w < cool; w += 10) { fprintf(out, "cooling: thermal %s after %.0f s\n", thermal(), w); fflush(out); sleep(10); }
    fprintf(out, "CPU load: %d threads at duty %.2f\n", ncpu, DUTY);
    fprintf(out, "device %s, thermal %s, low power %d, order %s, %.0f s each, rest %.0f s, target per frame %.1f ms vertex + %.1f ms fragment, %d heavy + %d tiny passes\n",
            dev.name.UTF8String, thermal(), (int)NSProcessInfo.processInfo.lowPowerModeEnabled, order.UTF8String, secs, rest, TV, TF, NH, NT); fflush(out);
    // calibration: 3 s of full load first (the clock a sustained load reaches quickly), then size vertex and fragment work at full barriers
    double t0 = CACurrentMediaTime(); while (CACurrentMediaTime() - t0 < 3) wait_ev(frame(0, 0, 3, 0, 0));
    for (int it = 0; it < 6; it++) {
        double tv = med_ms(1, 1, 9), tf = med_ms(1, 2, 9);
        fprintf(out, "calibration VN %d VK %d FK %d: vertex only %.2f ms, fragment only %.2f ms\n", VN, p->vk, p->fk, tv, tf); fflush(out);
        if (fabs(tv / TV - 1) < 0.1 && fabs(tf / TF - 1) < 0.1) break;
        VN = (int)(VN * TV / tv) + 1; p->fk = (int)(p->fk * TF / tf) + 1;
    }
    // probe reference: the fastest of 40 probes taken right after full-load frames; sizes the ALU probe to about 300 us at that clock
    for (int it = 0; it < 4; it++) { wait_ev(frame(0, 0, 3, 0, 0)); pr_t r = probe_once(); if (r.alu > 0) p->pk = (int)(p->pk * 300.0 / r.alu) + 1; }
    for (int i = 0; i < 40; i++) { wait_ev(frame(0, 0, 3, 0, 0)); pr_t r = probe_once(); if (r.alu > 0 && r.alu < ref_alu) ref_alu = r.alu; if (r.tiny > 0 && r.tiny < ref_tiny) ref_tiny = r.tiny; }
    wait_ev(frame(1, 0, 3, 0, 1)); pr_t rf = read_probe(1);
    fprintf(out, "probe: ALU loop %d, fastest %.1f us; tiny pass fastest %.1f us; serialised frame (full barriers) %.2f ms, free overlap %.2f ms; a serialised frame's tiny-pass median %.1f us, heavy median %.1f us\n",
            p->pk, ref_alu, ref_tiny, med_ms(1, 3, 9), med_ms(0, 3, 9), rf.ftiny, rf.fheavy); fflush(out);
    serial_ms = med_ms(1, 3, 9); VN0 = VN; FK0 = p->fk;
    // keepalive dispatch: about 1 ms at the launch clock
    p->pad = 20000; for (int it = 0; it < 4; it++) { keep_on = 1; keep_n = 0; keep_busy = 0; pthread_create(&keep_th, NULL, keep_loop, NULL); usleep(300000); keep_on = 0; pthread_join(keep_th, NULL);
        double ms = keep_n ? keep_busy * 1e3 / keep_n : 0; fprintf(out, "keepalive loop %d: %.2f ms per dispatch\n", p->pad, ms); fflush(out); if (ms > 0) p->pad = (int)(p->pad * 1.0 / ms) + 1; }
    if (arg(@"latency", @"0").intValue) { latency_run(); fprintf(out, "done\n"); fflush(out); return; }
    for (int i = 0; i < ncpu; i++) { pthread_t th; pthread_create(&th, NULL, cpu_load, NULL); }
    NSArray<NSString *> *toks = ([order containsString:@","] || [order rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"ABCD"] invertedSet]].location != NSNotFound) ? [order componentsSeparatedByString:@","] : ({ NSMutableArray *a = [NSMutableArray array]; for (NSUInteger i = 0; i < order.length; i++) [a addObject:[order substringWithRange:NSMakeRange(i, 1)]]; a; });
    for (NSUInteger i = 0; i < toks.count; i++) {
        if (i) { fprintf(out, "rest %.0f s\n", rest); fflush(out); for (double w = 0; w < rest; w += 30) { sleep(rest - w < 30 ? (unsigned)(rest - w) : 30); fprintf(out, "  resting %.0f s, thermal %s\n", w + 30 < rest ? w + 30 : rest, thermal()); fflush(out); }
                 pr_t r = probe_once(); fprintf(out, "after rest: probe ALU %.1f us (clock %.2f) after idle, thermal %s\n", r.alu, r.alu > 0 ? ref_alu / r.alu : 0, thermal()); fflush(out); }
        variant(toks[i].UTF8String, secs, every);
    }
    cpu_stop = 1; fprintf(out, "done\n"); fflush(out);
}
@interface SD : UIResponder <UIWindowSceneDelegate> @property (nonatomic, strong) UIWindow *window; @end
@implementation SD
- (void)scene:(UIScene *)s willConnectToSession:(UISceneSession *)ss options:(UISceneConnectionOptions *)o {
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)s]; UIViewController *vc = [UIViewController new]; vc.view.backgroundColor = UIColor.blackColor; self.window.rootViewController = vc; [self.window makeKeyAndVisible];
    UIApplication.sharedApplication.idleTimerDisabled = YES;
    layer = [CAMetalLayer layer]; layer.frame = CGRectMake(0, 100, 256, 256); layer.pixelFormat = MTLPixelFormatBGRA8Unorm; layer.drawableSize = CGSizeMake(256, 256); layer.device = MTLCreateSystemDefaultDevice(); [vc.view.layer addSublayer:layer];
    NSString *doc = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0]; out = fopen([doc stringByAppendingPathComponent:@"clock.txt"].fileSystemRepresentation, "w");
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{ @autoreleasepool { run(); } }); }
@end
@interface AD : UIResponder <UIApplicationDelegate> @end
@implementation AD
- (UISceneConfiguration *)application:(UIApplication *)a configurationForConnectingSceneSession:(UISceneSession *)s options:(UISceneConnectionOptions *)o {
    UISceneConfiguration *c = [[UISceneConfiguration alloc] initWithName:@"Default" sessionRole:s.role]; c.delegateClass = [SD class]; return c; }
@end
int main(int argc, char *argv[]) { @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass([AD class])); } }
