// Kernel passes (DM_NVN_KPASS, nvn_mtl.m kp_try, dm/gfx/tools/dmsh_kpass.py): a one-draw pass of a full-screen quad run as a compute kernel gives the same pixels as the render pass.
// A vertex / fragment pair in the shape of the translated shaders (SPIRV-Cross output) is written to a temporary directory, the generator makes the pair's kernel from it, and the same
// command list is replayed once as a render pass and once as a kernel pass: a mip-mapped texture sampled with implicit LOD (the kernel's quad gradients must give the hardware's LOD),
// two interpolated varyings, [[position]], dfdx, two colour outputs (RGBA8 and RGBA16F), a strip of 4 and a list of 6 vertices, odd target sizes, the 2x2 case where the quad's diagonal
// runs through pixel centres (the fill rule), a quad that covers a quarter of the target with a pending clear (the kernel writes the clear colour where no triangle covers), and culling
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t g_mod[MAX_MOD]; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int fail, count;
#define EXPECT(name, want, got) do { uint64_t w=(want), g=(got); count++; printf("%s expected %llu → got %llu %s\n", name, (unsigned long long)w, (unsigned long long)g, w==g?"✓":"✗"); fail += w != g; } while (0)
typedef struct { uint8_t *p; size_t n; } chain;
static chain chain_new(void) { chain c={0}; if (posix_memalign((void **)&c.p,getpagesize(),65536)) abort(); memset(c.p,0,65536); mtl_pool_add(c.p,65536); return c; }
static void emit(chain *c, unsigned op, const void *a, size_t n) { size_t z=(8+n+7)&~7ull; op_hdr h={op,(uint32_t)z}; memcpy(c->p+c->n,&h,8); if(n) memcpy(c->p+c->n+8,a,n); c->n+=z; }
static tex_t tex(unsigned w, unsigned h, unsigned levels, int fmt) { static uint64_t s=9000; tex_t t={.magic=MAGIC('T', 'E', 'X', 0), .serial =s, .off=(int64_t)(s-9000)<<22}; s++;
    t.d.width=w; t.d.height=h; t.d.depth=t.d.samples=1; t.d.levels=levels; t.d.target=NVN_TEXTURE_TARGET_2D; t.d.format=fmt; return t; }
static int reg(const tex_t *t, int levels) { static int id=1200; view_t v={.set_levels=1,.base_level=0,.nlevels=(uint8_t)levels}; mtl_reg_tex(id,t,&v); return id++; }
static void set_rt(chain *c, const tex_t *a, const tex_t *b, unsigned w, unsigned h) { p_set_rt r={.n=2}; r.color[0]=a; r.color[1]=b; for(int i=0;i<2;i++){r.has_cview[i]=1;r.cview[i].set_levels=1;r.cview[i].base_level=0;r.cview[i].nlevels=1;} emit(c,OP_SET_RT,&r,sizeof r);
    p_viewports v={.n=1};v.v[0][2]=w;v.v[0][3]=h;emit(c,OP_VIEWPORTS,&v,sizeof v);p_scissor sc={0,0,(int)w,(int)h};emit(c,OP_SCISSOR,&sc,sizeof sc); }
static void clear_color(chain *c, int i, float r, float g, float b, float a) { p_clear_color x={.index=i,.mask=15,.rgba={r,g,b,a}}; emit(c,OP_CLEAR_COLOR,&x,sizeof x); }
static void bind_prog(chain *c, prog_t *p) { p_bind_program b={p,3}; emit(c,OP_BIND_PROGRAM,&b,sizeof b); }
static void bind_tex(chain *c, uint64_t handle) { p_bind_handles b={.stage=1,.first=0,.n=1};b.h[0]=handle;emit(c,OP_BIND_TEX,&b,sizeof b); }
static void draw_cmd(chain *c, int prim, int n) { p_draw d={prim,0,n}; emit(c,OP_DRAW,&d,sizeof d); }
static void ds_off(chain *c) { ds_st d={0,0,NVN_DEPTH_FUNC_ALWAYS,0,NVN_STENCIL_FUNC_ALWAYS,NVN_STENCIL_FUNC_ALWAYS,NVN_STENCIL_OP_KEEP,NVN_STENCIL_OP_KEEP,NVN_STENCIL_OP_KEEP,NVN_STENCIL_OP_KEEP,NVN_STENCIL_OP_KEEP,NVN_STENCIL_OP_KEEP}; p_bind_state x={.kind=5}; memcpy(x.bytes,&d,sizeof d); emit(c,OP_BIND_STATE,&x,sizeof x); }
static void readback(const tex_t *t, unsigned w, unsigned h, unsigned bpp, uint8_t *out) {
    id<MTLBuffer> b=[g_dev newBufferWithLength:w*h*bpp options:MTLResourceStorageModeShared];
    [blit() copyFromTexture:tex_mtl(t) sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(w,h,1) toBuffer:b destinationOffset:0 destinationBytesPerRow:w*bpp destinationBytesPerImage:w*h*bpp];
    uint64_t f=mtl_sub_commit(); EXPECT("submit completed",1,mtl_wait(f,5000000000ull)); EXPECT("no error in commit feedback",0,mtl_last_commit_error()); memcpy(out,b.contents,w*h*bpp); }
static NvProg *g_tkeep[16]; static int g_tnkeep;
// The pair in the translator's shape. Vertex: 6 positions from a table (two triangles of a quad: a strip of 4 or a list of 6), scaled by a uniform (vp_c3[0].x), uv in locn0, a colour in locn1.
// Fragment: samples the texture at the uv with implicit LOD, writes RGBA8 (sampled rgb, colour.x) and RGBA16F (the position, colour.y, dfdx of the uv)
static const char *VS =
"#include <metal_stdlib>\n#include <simd/simd.h>\n\nusing namespace metal;\n\nstruct _10\n{\n    float4 _m0[4096];\n};\n\nstruct spvDescriptorSetBuffer0\n{\n    constant _10* vp_c3 [[id(0)]];\n};\n\n"
"struct main0_out\n{\n    float4 m_20 [[user(locn0)]];\n    float4 m_22 [[user(locn1)]];\n    float4 gl_Position [[position, invariant]];\n    float gl_PointSize [[point_size]];\n};\n\n"
"vertex main0_out main0(constant spvDescriptorSetBuffer0& spvDescriptorSet0 [[buffer(0)]], uint gl_VertexIndex [[vertex_id]])\n{\n    main0_out out = {};\n    out.gl_PointSize = 1.0;\n"
"    float _30 = (*spvDescriptorSet0.vp_c3)._m0[0].x;\n    float2 _32[6] = { float2(-1.0, -1.0), float2(1.0, -1.0), float2(-1.0, 1.0), float2(1.0, 1.0), float2(1.0, -1.0), float2(-1.0, 1.0) };\n"
"    float2 _34 = _32[gl_VertexIndex] * _30;\n    out.gl_Position.x = _34.x;\n    out.gl_Position.y = _34.y;\n    out.gl_Position.z = 0.25;\n    out.gl_Position.w = 1.0;\n"
"    out.m_20 = float4(_34.x * 0.5 + 0.5, 0.5 - _34.y * 0.5, 0.0, 1.0);\n    out.m_22 = float4(float(gl_VertexIndex) / 6.0, 1.0 - float(gl_VertexIndex) / 6.0, 0.0, 1.0);\n"
"    out.gl_Position.z = fma(out.gl_Position.z, 0.5, out.gl_Position.w * 0.5);\n    return out;\n}\n\n\n"
"vertex main0_out main0_z(constant spvDescriptorSetBuffer0& spvDescriptorSet0 [[buffer(0)]], uint gl_VertexIndex [[vertex_id]])\n{\n    main0_out out = {};\n    out.gl_PointSize = 1.0;\n"
"    float _30 = (*spvDescriptorSet0.vp_c3)._m0[0].x;\n    float2 _32[6] = { float2(-1.0, -1.0), float2(1.0, -1.0), float2(-1.0, 1.0), float2(1.0, 1.0), float2(1.0, -1.0), float2(-1.0, 1.0) };\n"
"    float2 _34 = _32[gl_VertexIndex] * _30;\n    out.gl_Position.x = _34.x;\n    out.gl_Position.y = _34.y;\n    out.gl_Position.z = 0.25;\n    out.gl_Position.w = 1.0;\n"
"    out.m_20 = float4(_34.x * 0.5 + 0.5, 0.5 - _34.y * 0.5, 0.0, 1.0);\n    out.m_22 = float4(float(gl_VertexIndex) / 6.0, 1.0 - float(gl_VertexIndex) / 6.0, 0.0, 1.0);\n    return out;\n}\n";
static const char *FS =
"#include <metal_stdlib>\n#include <simd/simd.h>\n\nusing namespace metal;\n\nstruct spvDescriptorSetBuffer0\n{\n    texture2d<float> fp_t_tcb_8 [[id(0)]];\n    sampler fp_t_tcb_8Smplr [[id(1)]];\n};\n\n"
"struct main0_out\n{\n    float4 m_30 [[color(0)]];\n    float4 m_31 [[color(1)]];\n};\n\nstruct main0_in\n{\n    float4 m_20 [[user(locn0)]];\n    float4 m_22 [[user(locn1)]];\n};\n\n"
"fragment main0_out main0(main0_in in [[stage_in]], constant spvDescriptorSetBuffer0& spvDescriptorSet0 [[buffer(0)]], float4 gl_FragCoord [[position]])\n{\n    main0_out out = {};\n"
"    float2 _50 = float2(in.m_20.x, in.m_20.y);\n    float4 _52 = spvDescriptorSet0.fp_t_tcb_8.sample(spvDescriptorSet0.fp_t_tcb_8Smplr, select(_50, float2(0.0), isnan(_50))).xyzw;\n"
"    float _54 = dfdx(in.m_20.x);\n    out.m_30 = float4(_52.x, _52.y, _52.z, in.m_22.x);\n    out.m_31 = float4(gl_FragCoord.x * 0.015625, gl_FragCoord.y * 0.015625, in.m_22.y, _54 * 64.0);\n    return out;\n}\n";
static char g_dir[256];
static void setup_prog(prog_t *pg) {
    snprintf(g_dir, sizeof g_dir, "/tmp/t_kpass_%d", (int)getpid()); mkdir(g_dir, 0755);
    char path[300]; snprintf(path, sizeof path, "%s/tvs_b.metal", g_dir); FILE *f = fopen(path, "w"); fputs(VS, f); fclose(f);
    snprintf(path, sizeof path, "%s/tfs_b.metal", g_dir); f = fopen(path, "w"); fputs(FS, f); fclose(f);
    char cmd[1024]; snprintf(cmd, sizeof cmd, "python3 ../tools/dmsh_kpass.py '%s' '%s' tvs_b tfs_b >/dev/null", g_dir, g_dir);
    EXPECT("the generator makes the pair's kernel", 0, system(cmd));
    setenv("DM_NVN_KPASS_DIR", g_dir, 1);
    NSError *e = nil; id<MTLLibrary> lv = [g_dev newLibraryWithSource:@(VS) options:nil error:&e]; if (!lv) { fprintf(stderr, "%s\n", e.localizedDescription.UTF8String); abort(); }
    id<MTLLibrary> lf = [g_dev newLibraryWithSource:@(FS) options:nil error:&e]; if (!lf) { fprintf(stderr, "%s\n", e.localizedDescription.UTF8String); abort(); }
    pg->serial = 8000; NvProg *p = [NvProg new];
    p->sh[0] = [NvShader new]; p->sh[0]->fn = [lv newFunctionWithName:@"main0"]; strcpy(p->sh[0]->key, "tvs_b"); p->sh[0]->rf.nb = 1; p->sh[0]->rf.b[0] = (nvn_rbind){.kind = NVN_RB_CBUF, .reg = 0, .aid = 0}; p->sh[0]->ae = [p->sh[0]->fn newArgumentEncoderWithBufferIndex:0];
    p->sh[1] = [NvShader new]; p->sh[1]->stage = 1; p->sh[1]->fn = [lf newFunctionWithName:@"main0"]; strcpy(p->sh[1]->key, "tfs_b"); p->sh[1]->rf.nb = 2;
    p->sh[1]->rf.b[0] = (nvn_rbind){.kind = NVN_RB_TEX, .reg = 0, .aid = 0, .dtt = 2}; p->sh[1]->rf.b[1] = (nvn_rbind){.kind = NVN_RB_SAMPT, .reg = 0, .aid = 1}; p->sh[1]->rf.color_mask = 3;
    p->sh[1]->ae = [p->sh[1]->fn newArgumentEncoderWithBufferIndex:0];
    g_tkeep[g_tnkeep++] = p; serial_put(pg->serial, p);
}
static prog_t t_pg; static tex_t t_src; static int t_src_id, t_samp_id; static float *t_ubo;
// One replay of the list: targets a (RGBA8) and b (RGBA16F) of w x h, a strip of 4 or a list of 6, the quad scaled, a clear when asked, the cull mode; both targets read back
static void run_case(int kernel, unsigned w, unsigned h, int strip, float scale, int clear, int cull, uint8_t *pa, uint8_t *pb) {
    tex_t a = tex(w, h, 1, NVN_FORMAT_RGBA8), b = tex(w, h, 1, NVN_FORMAT_RGBA16F);
    chain c = chain_new();
    set_rt(&c, &a, &b, w, h); if (clear) { clear_color(&c, 0, 0.2f, 0.4f, 0.6f, 0.8f); clear_color(&c, 1, 0.1f, 0.3f, 0.5f, 0.7f); } ds_off(&c); bind_prog(&c, &t_pg); bind_tex(&c, (uint64_t)t_src_id | (uint64_t)t_samp_id << 20);
    draw_cmd(&c, strip ? NVN_DRAW_PRIMITIVE_TRIANGLE_STRIP : NVN_DRAW_PRIMITIVE_TRIANGLES, strip ? 4 : 6);
    emit(&c, OP_END, NULL, 0); state_reset(); memset(&R, 0, sizeof R); vis_clear(); g_vis_on = g_vis_counting = 0;
    t_ubo[0] = scale; S.ubo[0][0] = (p_bind_buf){(uint64_t)t_ubo, 256}; S.poly.cull = cull;
    g_kp_test_mode = kernel; uint64_t n0 = g_kp_n;
    mtl_sub_begin(); uint64_t hh = (uint64_t)c.p; mtl_sub_index(&hh, 1); mtl_exec(c.p);
    if (kernel) EXPECT("the draw ran as a kernel pass", 1, g_kp_n - n0);
    readback(&a, w, h, 4, pa); mtl_sub_begin(); readback(&b, w, h, 8, pb);
}
static float half_to_float(uint16_t h) { return (float)(*(_Float16 *)&h); }
static void compare(const char *name, unsigned w, unsigned h, int strip, float scale, int clear, int cull) {
    size_t n = (size_t)w * h; uint8_t *ra = malloc(n * 4), *rb = malloc(n * 8), *ka = malloc(n * 4), *kb = malloc(n * 8);
    run_case(0, w, h, strip, scale, clear, cull, ra, rb); run_case(1, w, h, strip, scale, clear, cull, ka, kb);
    int maxa = 0; size_t bad = 0; for (size_t i = 0; i < n * 4; i++) { int d = abs(ra[i] - ka[i]); if (d > maxa) maxa = d; if (d > 2) bad++; }
    float maxb = 0; for (size_t i = 0; i < n * 4; i++) { float d = fabsf(half_to_float(((uint16_t *)rb)[i]) - half_to_float(((uint16_t *)kb)[i])); if (d > maxb) maxb = d; }
    char s[200]; snprintf(s, sizeof s, "%s: RGBA8 bytes off by more than 2 (max %d)", name, maxa); EXPECT(s, 0, bad);
    snprintf(s, sizeof s, "%s: RGBA16F within 0.004 (max difference %.5f)", name, maxb); EXPECT(s, 1, maxb <= 0.004f);
    int lit = 0; for (size_t i = 0; i < n; i++) lit += ra[i * 4 + 3] != 0; snprintf(s, sizeof s, "%s: the render pass drew something (pixels with alpha)", name); EXPECT(s, 1, cull == NVN_FACE_FRONT ? lit == 0 : lit > 0);   // the strip's first triangle is counter-clockwise in NDC, the front face by default
    free(ra); free(rb); free(ka); free(kb);
}
int main(void) { @autoreleasepool { setvbuf(stdout, NULL, _IONBF, 0); setenv("DM_NVN_KPASS", "1", 1);
    mtl_init(); setup_prog(&t_pg);
    // the source texture: 64x64 with 7 levels, each a solid colour of its own (level k: r = 32 k, g = 255 - 32 k, b = 64 + 16 k): what the sample returns tells the LOD taken
    t_src = tex(64, 64, 7, NVN_FORMAT_RGBA8); t_src_id = reg(&t_src, 7);
    samp_par sp = {NVN_MIN_FILTER_LINEAR_MIPMAP_LINEAR, NVN_MAG_FILTER_LINEAR, NVN_WRAP_MODE_CLAMP_TO_EDGE, NVN_WRAP_MODE_CLAMP_TO_EDGE, NVN_WRAP_MODE_CLAMP_TO_EDGE, 0, 0, 0, 0.0f, 15.0f, 0.0f, 1.0f, {0, 0, 0, 0}};
    t_samp_id = 77; mtl_reg_samp(t_samp_id, &sp);
    if (posix_memalign((void **)&t_ubo, getpagesize(), getpagesize())) abort(); memset(t_ubo, 0, getpagesize()); mtl_pool_add(t_ubo, getpagesize());
    mtl_sub_begin(); { id<MTLTexture> mt = tex_mtl(&t_src); id<MTLBuffer> fill = [g_dev newBufferWithLength:64 * 64 * 4 options:MTLResourceStorageModeShared]; res_add(fill); uint8_t *px = fill.contents;
        for (int k = 0; k < 7; k++) { unsigned lw = 64 >> k; for (unsigned i = 0; i < lw * lw; i++) { px[4 * i] = (uint8_t)(32 * k); px[4 * i + 1] = (uint8_t)(255 - 32 * k); px[4 * i + 2] = (uint8_t)(64 + 16 * k); px[4 * i + 3] = 255; }
            enc_b_copy_buffer_texture(blit(), fill, 0, lw * 4, lw * lw * 4, MTLSizeMake(lw, lw, 1), mt, 0, (NSUInteger)k, MTLOriginMake(0, 0, 0)); uint64_t f = mtl_sub_commit(); mtl_wait(f, 5000000000ull); mtl_sub_begin(); }
        uint64_t f = mtl_sub_commit(); mtl_wait(f, 5000000000ull); }
    compare("strip, full quad, 16x16 (LOD 2)", 16, 16, 1, 1.0f, 0, NVN_FACE_NONE);
    compare("list of 6, full quad, 23x17", 23, 17, 0, 1.0f, 0, NVN_FACE_NONE);
    compare("strip, 2x2 (the diagonal through pixel centres)", 2, 2, 1, 1.0f, 0, NVN_FACE_NONE);
    compare("strip, 1x1", 1, 1, 1, 1.0f, 0, NVN_FACE_NONE);
    compare("quarter quad with a pending clear, 16x16", 16, 16, 1, 0.5f, 1, NVN_FACE_NONE);
    compare("quarter quad with a pending clear, list, 23x17", 23, 17, 0, 0.5f, 1, NVN_FACE_NONE);
    compare("full quad, cull back (the quad is drawn)", 16, 16, 1, 1.0f, 1, NVN_FACE_BACK);
    compare("full quad, cull front (nothing drawn, the clear remains)", 16, 16, 1, 1.0f, 1, NVN_FACE_FRONT);
    printf("== %d checks, %d failed ==\n", count, fail); return fail != 0; } }
