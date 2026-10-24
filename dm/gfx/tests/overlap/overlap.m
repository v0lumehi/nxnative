// Metal 4 overlap micro-test: do consecutive render passes overlap one pass's vertex work with the previous pass's fragment work, and under which barriers?
// Each pass renders its own 1024x1024 target with one vertex-heavy draw (triangles culled after the vertex stage) and one fragment-heavy full-screen triangle.
// Frames of NP passes are timed by the GPU span of their command buffers. Variants: vertex only, fragment only, both with full barriers (the host's default),
// no barriers, the host's 'game' end barrier, one command buffer per pass, and 'game' with a new command buffer every few passes (the host's segments)
#import <Metal/Metal.h>
#import <Foundation/Foundation.h>
#include <stdio.h>
enum { NP = 20, NF = 24 };
static id<MTLDevice> dev; static id<MTL4CommandQueue> q; static id<MTL4CommandAllocator> al[2]; static id<MTLSharedEvent> ev; static uint64_t evv;
static id<MTLTexture> tgt[NP]; static id<MTLRenderPipelineState> psV, psF; static id<MTL4ArgumentTable> at;
static int VN = 300000, VK = 64, FK = 64;   // vertices per vertex draw, loop iterations in the vertex and fragment shaders
static NSString *src(void) { return [NSString stringWithFormat:@
    "#include <metal_stdlib>\nusing namespace metal;\nstruct O { float4 p [[position]]; float4 c; };\n"
    "vertex O vheavy(uint v [[vertex_id]]) { float x = float(v) * 1e-6; for (int i = 0; i < %d; i++) x = fma(x, 1.0001, sin(x) * 0.5); O o; o.p = float4(4.0 + x * 1e-9, 4.0, 0.5, 1.0); o.c = float4(x); return o; }\n"
    "vertex O vfull(uint v [[vertex_id]]) { O o; float2 t = float2((v << 1) & 2, v & 2); o.p = float4(t * 2.0 - 1.0, 0.5, 1.0); o.c = float4(t, 0, 1); return o; }\n"
    "fragment float4 fnone(O i [[stage_in]]) { return i.c; }\n"
    "fragment float4 fheavy(O i [[stage_in]]) { float x = i.c.x + i.p.x * 1e-4; for (int k = 0; k < %d; k++) x = fma(x, 1.0001, sin(x) * 0.5); return float4(x, i.c.y, 0, 1); }\n", VK, FK]; }
static id<MTLRenderPipelineState> pso(id<MTLLibrary> l, NSString *v, NSString *f) {
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new]; d.vertexFunction = [l newFunctionWithName:v]; d.fragmentFunction = [l newFunctionWithName:f];
    d.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm; NSError *e = nil; id<MTLRenderPipelineState> p = [dev newRenderPipelineStateWithDescriptor:d error:&e];
    if (!p) { fprintf(stderr, "pipeline: %s\n", e.localizedDescription.UTF8String); exit(1); } return p; }
// mode: 0 full barriers, 1 none, 2 game end barrier, 3 command buffer per pass (no barriers), 4 game + new command buffer every 4 passes; what: 1 vertex, 2 fragment, 3 both
static double frame(int mode, int what) {
    static int ai; id<MTL4CommandAllocator> a = al[ai++ & 1]; [a reset];
    __block double t0 = 1e30, t1 = 0; __block int pending = 0; NSMutableArray *cbs = [NSMutableArray array];
    id<MTL4CommandBuffer> cb = nil;
    for (int p = 0; p < NP; p++) {
        int newcb = !cb || (mode == 3) || (mode == 4 && p % 4 == 0);
        if (newcb) { if (cb) { [cb endCommandBuffer]; [cbs addObject:cb]; } cb = [dev newCommandBuffer]; [cb beginCommandBufferWithAllocator:a]; }
        MTL4RenderPassDescriptor *rp = [MTL4RenderPassDescriptor new]; rp.colorAttachments[0].texture = tgt[p]; rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTL4RenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
        if (mode == 0) [e barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice];
        [e setArgumentTable:at atStages:MTLRenderStageVertex | MTLRenderStageFragment];
        if (what & 1) { [e setRenderPipelineState:psV]; [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:(NSUInteger)VN]; }
        if (what & 2) { [e setRenderPipelineState:psF]; [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; }
        if (mode == 0) [e barrierAfterStages:MTLStageAll beforeQueueStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice];
        if (mode == 2 || mode == 4) [e barrierAfterStages:MTLStageVertex | MTLStageFragment beforeQueueStages:MTLStageFragment | MTLStageDispatch | MTLStageBlit visibilityOptions:MTL4VisibilityOptionDevice];
        [e endEncoding];
    }
    [cb endCommandBuffer]; [cbs addObject:cb];
    for (id<MTL4CommandBuffer> c in cbs) {
        MTL4CommitOptions *o = [MTL4CommitOptions new]; pending++;
        [o addFeedbackHandler:^(id<MTL4CommitFeedback> f) { @synchronized (cbs) { if (f.GPUStartTime < t0) t0 = f.GPUStartTime; if (f.GPUEndTime > t1) t1 = f.GPUEndTime; } }];
        id<MTL4CommandBuffer> one[1] = {c}; [q commit:one count:1 options:o];
    }
    [q signalEvent:ev value:++evv]; [ev waitUntilSignaledValue:evv timeoutMS:10000];
    for (int w = 0; w < 200; w++) { @synchronized (cbs) { if (t1 > 0 && t0 < 1e29) break; } usleep(1000); }   // feedback handlers run on their own queue
    usleep(2000);
    return (t1 - t0) * 1e3;
}
static double med(int mode, int what) { double v[NF]; for (int i = 0; i < NF; i++) v[i] = frame(mode, what);
    for (int i = 0; i < NF; i++) for (int j = i + 1; j < NF; j++) if (v[j] < v[i]) { double t = v[i]; v[i] = v[j]; v[j] = t; } return v[NF / 2]; }
void overlap_run(FILE *out) {
    dev = MTLCreateSystemDefaultDevice(); NSError *e = nil;
    q = [dev newMTL4CommandQueue]; for (int i = 0; i < 2; i++) al[i] = [dev newCommandAllocator]; ev = [dev newSharedEvent];
    MTLResidencySetDescriptor *rd = [MTLResidencySetDescriptor new]; id<MTLResidencySet> rs = [dev newResidencySetWithDescriptor:rd error:&e];
    for (int i = 0; i < NP; i++) { MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:1024 height:1024 mipmapped:NO];
        d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead; d.storageMode = MTLStorageModePrivate; tgt[i] = [dev newTextureWithDescriptor:d]; [rs addAllocation:tgt[i]]; }
    [rs commit]; [q addResidencySet:rs];
    MTL4ArgumentTableDescriptor *ad = [MTL4ArgumentTableDescriptor new]; ad.maxBufferBindCount = 1; at = [dev newArgumentTableWithDescriptor:ad error:&e];
    fprintf(out, "device %s\n", dev.name.UTF8String);
    // calibrate: vertex-only and fragment-only frames of roughly 8 ms each
    for (int it = 0; it < 6; it++) {
        id<MTLLibrary> l = [dev newLibraryWithSource:src() options:nil error:&e]; if (!l) { fprintf(out, "library: %s\n", e.localizedDescription.UTF8String); return; }
        psV = pso(l, @"vheavy", @"fnone"); psF = pso(l, @"vfull", @"fheavy");
        double tv = med(1, 1), tf = med(1, 2); fprintf(out, "calibration VN %d VK %d FK %d: vertex only %.2f ms, fragment only %.2f ms\n", VN, VK, FK, tv, tf); fflush(out);
        if (tv > 6 && tv < 12 && tf > 6 && tf < 12) break;
        VN = (int)(VN * 8.0 / tv) + 1; FK = (int)(FK * 8.0 / tf) + 1;   // vertex work scales by the vertex count (the loop count changed how the compiler unrolled)
    }
    const char *names[5] = {"full barriers (host default)", "no barriers", "game end barrier", "command buffer per pass, no barriers", "game end barrier, new command buffer every 4 passes"};
    for (int rep = 0; rep < 2; rep++) {
        double tv = med(1, 1), tf = med(1, 2);
        fprintf(out, "round %d: vertex only %.2f ms, fragment only %.2f ms, sum %.2f ms\n", rep, tv, tf, tv + tf);
        for (int m = 0; m < 5; m++) { double t = med(m, 3); fprintf(out, "  %-52s %.2f ms  hidden %.0f%% of the smaller part\n", names[m], t, 100 * (tv + tf - t) / (tv < tf ? tv : tf)); fflush(out); }
    }
}
#if !TARGET_OS_IPHONE
int main(void) { @autoreleasepool { overlap_run(stdout); } return 0; }
#endif
