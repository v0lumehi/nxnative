// Remap microbenchmark (Mac, measurement only; clang -O2 -fobjc-arc -framework Metal -framework Foundation remap_bench.m): does a CPU remap of pages under a newBufferWithBytesNoCopy MTLBuffer leave the GPU on the old pages, and what do fault + copy + remap and the remap back (through a second view of the pages) cost
#import <Metal/Metal.h>
#include <sys/mman.h>
#include <mach/mach.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
static double now(void) { return CFAbsoluteTimeGetCurrent(); }
enum { NP = 256 };
static uint8_t *base, *alias; static size_t PG; static uint8_t *stage;
static int faults; static double fault_t;
// copy-on-write fault: keep a memory entry of the original page, map a staging page with its contents at the same address
static void on_segv(int sig, siginfo_t *si, void *uc) {
    double t0 = now(); uint8_t *a = (uint8_t *)((uintptr_t)si->si_addr & ~(PG - 1)); size_t i = (size_t)(a - base) / PG;
    (void)i;
    memcpy(stage, a, PG);   // the page as the GPU's frame sees it
    vm_address_t at = (vm_address_t)a;
    kern_return_t kr = vm_allocate(mach_task_self(), &at, PG, VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE); if (kr) { write(2, "vm_allocate failed\n", 19); _exit(1); }
    memcpy(a, stage, PG);   // the CPU goes on with a copy
    faults++; fault_t += now() - t0; (void)sig; (void)uc;
}
int main(void) {
    @autoreleasepool {
    PG = (size_t)getpagesize(); size_t len = NP * PG;
    base = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); stage = mmap(NULL, PG, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    for (size_t i = 0; i < len / 4; i++) ((uint32_t *)base)[i] = 1;
    { vm_address_t al = 0; vm_prot_t cp, mp; if (vm_remap(mach_task_self(), &al, len, 0, VM_FLAGS_ANYWHERE, mach_task_self(), (vm_address_t)base, FALSE, &cp, &mp, VM_INHERIT_NONE)) { printf("alias failed\n"); return 1; } alias = (uint8_t *)al; }   // a second view of the pool's pages, kept for good
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice(); id<MTLCommandQueue> q = [dev newCommandQueue];
    id<MTLBuffer> buf = [dev newBufferWithBytesNoCopy:base length:len options:MTLResourceStorageModeShared deallocator:nil];
    id<MTLBuffer> out = [dev newBufferWithLength:NP * 4 options:MTLResourceStorageModeShared];
    NSError *e; id<MTLLibrary> l = [dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\nkernel void k(device const uint *b [[buffer(0)]], device uint *o [[buffer(1)]], constant uint &stride [[buffer(2)]], uint i [[thread_position_in_grid]]) {"
        "float x = i; for (int j = 0; j < 4000000; j++) x = fma(x, 1.000001, 0.5); o[i] = b[i * stride] + (x < 0 ? 1u : 0u); }" options:nil error:&e];
    id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:[l newFunctionWithName:@"k"] error:&e];
    uint32_t stride = (uint32_t)(PG / 4);
    printf("page size %zu, %d pages\n", PG, NP);
    // 1. GPU reads while the CPU remaps every page (copy-on-write) and writes 2
    struct sigaction sa = {0}; sa.sa_sigaction = on_segv; sa.sa_flags = SA_SIGINFO; sigaction(SIGBUS, &sa, NULL); sigaction(SIGSEGV, &sa, NULL);
    id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder]; [ce setComputePipelineState:ps]; [ce setBuffer:buf offset:0 atIndex:0]; [ce setBuffer:out offset:0 atIndex:1]; [ce setBytes:&stride length:4 atIndex:2];
    [ce dispatchThreads:MTLSizeMake(NP, 1, 1) threadsPerThreadgroup:MTLSizeMake(32, 1, 1)]; [ce endEncoding];
    double t0 = now(); mprotect(base, len, PROT_READ); double tp = now() - t0;
    [cb commit];
    t0 = now(); for (int i = 0; i < NP; i++) ((volatile uint32_t *)(base + i * PG))[0] = 2; double tw = now() - t0;
    [cb waitUntilCompleted]; double gpu_ms = (cb.GPUEndTime - cb.GPUStartTime) * 1e3;
    int old = 0, neu = 0; for (int i = 0; i < NP; i++) { uint32_t v = ((uint32_t *)out.contents)[i]; if (v == 1) old++; else if (v == 2) neu++; }
    printf("GPU kernel %.1f ms (the CPU writes ran %s it); GPU read the old page in %d of %d, the CPU's new one in %d\n", gpu_ms, tw * 1e3 < gpu_ms ? "inside" : "NOT inside", old, NP, neu);
    printf("protect %d pages: %.1f us; faults %d, %.2f us each (entry + copy + remap + copy back), whole write loop %.2f us a page\n", NP, tp * 1e6, faults, fault_t / faults * 1e6, tw / NP * 1e6);
    // 2. what the MTLBuffer holds now (the GPU's view: old pages), what the CPU sees (new pages)
    printf("buffer contents (CPU through the buffer's pointer): %u; a fresh GPU read of page 0 below\n", ((uint32_t *)buf.contents)[0]);
    cb = [q commandBuffer]; id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder]; [be copyFromBuffer:buf sourceOffset:0 toBuffer:out destinationOffset:0 size:4]; [be endEncoding]; [cb commit]; [cb waitUntilCompleted];
    printf("GPU blit read of page 0 after the remap: %u (1 = old page, 2 = the CPU's)\n", ((uint32_t *)out.contents)[0]);
    // 3. write back: GPU blit stage -> old page through the buffer is what the scheme does; here: remap back the old pages (memory entries) and time it
    t0 = now(); int bad = 0;
    for (int i = 0; i < NP; i++) { vm_address_t at = (vm_address_t)(base + i * PG); vm_prot_t cp, mp;
        if (vm_remap(mach_task_self(), &at, PG, 0, VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE, mach_task_self(), (vm_address_t)(alias + i * PG), FALSE, &cp, &mp, VM_INHERIT_NONE)) bad++; }
    double tb = now() - t0;
    printf("remap back %d pages: %.2f us a page, %d failed; CPU now reads %u (1 = the old page again)\n", NP, tb / NP * 1e6, bad, ((uint32_t *)base)[0]);
    }
    return 0;
}
