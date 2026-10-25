// Scene upscale (DM_PRESENT_UPSCALE=metalfx-scene, nvn_mtl.m scup_draw): the pieces that do not need a game's shaders, on real Metal.
//   1. the LOD bias of the scene's passes: samp_rid gives a mipmapped sampler a biased copy while g_samp_bias is set, the same copy while the bias stays, a new one when it changes,
//      and the sampler itself for a sampler without mips or with no bias; scup_pass_bias only for passes of the scene's size, in the frame after the scene was scaled
//   2. MetalFX's spatial scaler on the replay's format (RGB10A2, Breath of the Wild's output) from a corner of a larger input (a smaller dynamic-resolution scene) through rec_fx, then the
//      copy into a larger target at an offset, as scup_draw encodes them
#define nvn_game_fps nvn_game_fps_mtl_default
#define nvn_var_fps nvn_var_fps_mtl_default
#include "../nvn/nvn_mtl.m"
#undef nvn_game_fps
#undef nvn_var_fps
#define g_ft g_ft_hle
#include "../nvn/hle_nvn.c"
#undef g_ft
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t g_mod[MAX_MOD]; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(name, ok) do { int pass = !!(ok); checks++; failed += !pass; printf("%s: %s\n", name, pass ? "PASS" : "FAIL"); } while (0)

static uint32_t rgb10a2(float r, float g, float b) { return (uint32_t)(r * 1023 + 0.5f) | (uint32_t)(g * 1023 + 0.5f) << 10 | (uint32_t)(b * 1023 + 0.5f) << 20 | 3u << 30; }
static void px(uint32_t v, float c[3]) { c[0] = (v & 1023) / 1023.0f; c[1] = (v >> 10 & 1023) / 1023.0f; c[2] = (v >> 20 & 1023) / 1023.0f; }
static int near(uint32_t v, float r, float g, float b) { float c[3]; px(v, c); return fabsf(c[0] - r) < 0.06f && fabsf(c[1] - g) < 0.06f && fabsf(c[2] - b) < 0.06f; }

int main(void) { @autoreleasepool {
    mtl_init();
    // 1. LOD bias
    samp_par mip = {.minf = 5, .magf = 1, .lod_min = 0, .lod_max = 14, .lod_bias = -1, .aniso = 1}, flat = mip; flat.minf = 1;
    mtl_reg_samp(5, &mip); mtl_reg_samp(6, &flat);
    os_unfair_lock_lock(&g_rmu);
    CHECK("samplers made", samp_fast(5) && samp_fast(6));
    uint64_t b5 = samp_rid(5), b6 = samp_rid(6);
    g_samp_bias = -0.6875f;
    uint64_t v5 = samp_rid(5), v5again = samp_rid(5), v6 = samp_rid(6);
    CHECK("a mipmapped sampler gets a biased copy in a scene pass", v5 && v5 != b5);
    CHECK("the same copy while the bias stays", v5 == v5again);
    CHECK("a sampler without mips keeps itself", v6 == b6);
    g_samp_bias = -0.75f;
    uint64_t w5 = samp_rid(5);
    CHECK("a new copy for another bias", w5 && w5 != b5 && g_sbias_made == -0.75f);
    g_samp_bias = 0;
    CHECK("no bias: the sampler itself", samp_rid(5) == b5);
    CHECK("an unregistered sampler: the dummy", samp_rid(0) == dummy_samp_rid());
    os_unfair_lock_unlock(&g_rmu);
    g_scup_sw = 1600; g_scup_sh = 900; g_scup_bias = -0.6875f; g_scup_frame = 10; atomic_store(&g_cur_frame, 11);
    CHECK("a pass of the scene's size takes the bias", scup_pass_bias(1600, 900) == -0.6875f);
    CHECK("a pass of another size does not (the HUD's, a shadow map)", scup_pass_bias(2560, 1440) == 0 && scup_pass_bias(800, 450) == 0);
    atomic_store(&g_cur_frame, 13);
    CHECK("nor two frames after the last scaled scene (a menu without the 3D view)", scup_pass_bias(1600, 900) == 0);

    // 2. MetalFX on RGB10A2: a 48x27 scene in the corner of a 64x36 input (left red, right blue) into 128x72, copied to 16,8 of a 160x90 green target
    if (!g_q4 || ![MTLFXSpatialScalerDescriptor supportsMetal4FX:g_dev]) { printf("no Metal 4 MetalFX: part 2 skipped\n"); }
    else {
        const NSUInteger iw = 64, ih = 36, cw = 48, ch = 27, ow = 128, oh = 72, tw = 160, th = 90, ox = 16, oy = 8; const MTLPixelFormat pf = MTLPixelFormatRGB10A2Unorm;
        MTLFXSpatialScalerDescriptor *d = [MTLFXSpatialScalerDescriptor new];
        d.colorTextureFormat = pf; d.outputTextureFormat = pf; d.inputWidth = iw; d.inputHeight = ih; d.outputWidth = ow; d.outputHeight = oh;
        d.colorProcessingMode = MTLFXSpatialScalerColorProcessingModePerceptual;
        NSError *e = nil; id<MTL4Compiler> comp = [g_dev newCompilerWithDescriptor:[MTL4CompilerDescriptor new] error:&e];
        id<MTL4FXSpatialScaler> sc = comp ? [d newSpatialScalerWithDevice:g_dev compiler:comp] : nil;
        CHECK("MetalFX makes an RGB10A2 spatial scaler", sc != nil);
        if (sc) {
            MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pf width:iw height:ih mipmapped:NO];
            td.storageMode = MTLStorageModeShared; td.usage = sc.colorTextureUsage | MTLTextureUsageShaderRead;
            id<MTLTexture> in = [g_dev newTextureWithDescriptor:td];
            td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pf width:ow height:oh mipmapped:NO]; td.storageMode = MTLStorageModePrivate; td.usage = sc.outputTextureUsage | MTLTextureUsageShaderRead;
            id<MTLTexture> out = [g_dev newTextureWithDescriptor:td];
            td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pf width:tw height:th mipmapped:NO]; td.storageMode = MTLStorageModeShared; td.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
            id<MTLTexture> dst = [g_dev newTextureWithDescriptor:td];
            uint32_t *a = malloc(iw * ih * 4), *t = malloc(tw * th * 4);
            for (NSUInteger y = 0; y < ih; y++) for (NSUInteger x = 0; x < iw; x++) a[y * iw + x] = x >= cw || y >= ch ? rgb10a2(1, 1, 1) : x < cw / 2 ? rgb10a2(0.9f, 0.1f, 0.1f) : rgb10a2(0.1f, 0.1f, 0.9f);   // white outside the scene: must not show
            for (NSUInteger i = 0; i < tw * th; i++) t[i] = rgb10a2(0, 1, 0);
            [in replaceRegion:MTLRegionMake2D(0, 0, iw, ih) mipmapLevel:0 withBytes:a bytesPerRow:iw * 4];
            [dst replaceRegion:MTLRegionMake2D(0, 0, tw, th) mipmapLevel:0 withBytes:t bytesPerRow:tw * 4];
            res_add(in); res_add(out); res_add(dst); res_commit();
            id<MTL4CommandAllocator> al = [g_dev newCommandAllocator]; id<MTL4CommandBuffer> cb = [g_dev newCommandBuffer]; id<MTLSharedEvent> ev = [g_dev newSharedEvent];
            [cb beginCommandBufferWithAllocator:al];
            rec_fx(cb, sc, in, out, cw, ch);
            id<MTL4ComputeCommandEncoder> ce = [cb computeCommandEncoder];
            [ce barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice];
            [ce copyFromTexture:out sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(ow, oh, 1) toTexture:dst destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(ox, oy, 0)];
            [ce endEncoding]; [cb endCommandBuffer];
            [g_q4 commit:&cb count:1]; [g_q4 signalEvent:ev value:1];
            CHECK("the GPU finishes", [ev waitUntilSignaledValue:1 timeoutMS:10000]);
            [dst getBytes:t bytesPerRow:tw * 4 fromRegion:MTLRegionMake2D(0, 0, tw, th) mipmapLevel:0];
            int red = 1, blue = 1, green = 1, white = 0;
            for (NSUInteger y = oy + 4; y < oy + oh - 4; y++) {
                for (NSUInteger x = ox + 4; x < ox + ow / 2 - 8; x++) red &= near(t[y * tw + x], 0.9f, 0.1f, 0.1f);
                for (NSUInteger x = ox + ow / 2 + 8; x < ox + ow - 4; x++) blue &= near(t[y * tw + x], 0.1f, 0.1f, 0.9f);
                for (NSUInteger x = ox; x < ox + ow; x++) white |= near(t[y * tw + x], 1, 1, 1); }
            for (NSUInteger y = 0; y < th; y++) for (NSUInteger x = 0; x < tw; x++) if (x < ox || y < oy || x >= ox + ow || y >= oy + oh) green &= near(t[y * tw + x], 0, 1, 0);
            CHECK("the scene's left half is red across the output's left half", red);
            CHECK("its right half blue", blue);
            CHECK("nothing of the input beyond the scene's corner is scaled in", !white);
            CHECK("the target outside the viewport keeps its content", green);
            free(a); free(t);
        }
    }
    printf("%d checks, %d failed\n", checks, failed);
    return failed != 0;
} }
