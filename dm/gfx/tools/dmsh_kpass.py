#!/usr/bin/env python3
"""Kernel passes (DM_NVN_KPASS): a render pass of one draw of at most two triangles (a full-screen quad as a rule) with no depth / stencil test and no blending,
replaced by one compute dispatch that runs the pair's vertex shader for its 3-6 vertices, rasterizes the triangles itself (pixel centres, top-left fill rule, perspective-correct
interpolation of the varyings) and runs the fragment shader body per pixel, writing the colour outputs with texture writes. A chain of such passes then runs inside one compute encoder
with encoder-local barriers (about 3-5 us a pass on an M2 Max) instead of one render encoder each (about 35-42 us): the encoder boundaries, not the dispatches, are what a tiny pass costs.

Usage: dmsh_kpass.py <msl dir> <out dir> <vs key> <fs key> [...more pairs]   (keys as the host names them, with the _b suffix; the pair's library is <vs>__<fs>_k.metallib,
       its description <vs>__<fs>_k.json; a pair that cannot be made writes <vs>__<fs>_k.json with "unsupported": reason, so the host asks once)
       dmsh_kpass.py --pairs <file> <msl dir> <out dir>                       (a file of "vs<TAB>fs" lines, as the host's DM_NVN_KPASS_WANT writes)

What it rewrites (the translated MSL is SPIRV-Cross output of one shape, which the regular expressions below rely on; anything else is "unsupported" and the pass stays a render pass):
  vertex:   every identifier of the form _N is prefixed with v (its structs and helpers share names with the fragment shader's), main0 and main0_z become plain functions taking the
            attributes as a struct and the vertex / instance indices as parameters; the stage attributes of the structs are dropped
  fragment: main0 becomes a plain function; discard_fragment() sets a flag; a 2D sample with implicit LOD takes the gradients of its coordinate over the 2x2 quad (quad_shuffle_xor,
            exactly the hardware's coarse derivatives, since the kernel runs its threads as 2x2 quads of pixels), dfdx / dfdy / fwidth likewise; [[position]] is the pixel centre with
            the interpolated depth and 1 / w; [[front_facing]] follows the triangle's winding
  kernel:   dm_kpass: 64 threads a threadgroup = 16 quads = an 8x8 tile of the dispatch rectangle; per pixel the triangle test, the interpolation, the fragment body and the writes
"""
import json, os, re, subprocess, sys

TG = 64   # threads per threadgroup: 16 quads of 2x2 pixels, an 8x8 tile

class Unsupported(Exception): pass

def strip_attrs(members):
    """'float4 m_26 [[user(locn0)]];' lines → [(type, name, locn or None, flat)]"""
    out = []
    for m in re.finditer(r'^\s*(\w+)\s+(\w+)(?:\s*\[\[(.*?)\]\])?;', members, re.M):
        ty, nm, at = m.group(1), m.group(2), m.group(3) or ''
        locn = re.search(r'user\(locn(\d+)\)', at)
        out.append((ty, nm, int(locn.group(1)) if locn else None, 'flat' in at, at))
    return out

def struct_body(src, name):
    m = re.search(r'\nstruct %s\s*\{(.*?)\n\};' % re.escape(name), src, re.S)
    return m.group(1) if m else None

def fn_text(src, sig_re):
    """The whole function whose signature matches sig_re (from its first keyword to the closing brace at column 0)"""
    m = re.search(sig_re, src)
    if not m: return None, None
    j = src.find('\n}\n', m.start())
    if j < 0: return None, None
    return src[m.start():j + 3], m

def params_of(sig):
    """Parameter list text → [(decl without attribute, attribute text)]"""
    inner = sig[sig.index('(') + 1:sig.rindex(')')]
    ps = []
    for p in split_top(inner):
        p = p.strip()
        if not p: continue
        a = re.search(r'\[\[(.*?)\]\]\s*$', p)
        ps.append((p[:a.start()].strip() if a else p, a.group(1) if a else ''))
    return ps

def split_top(s):
    """Split on commas at nesting depth 0"""
    out, depth, cur = [], 0, ''
    for ch in s:
        if ch in '(<[': depth += 1
        elif ch in ')>]': depth -= 1
        if ch == ',' and depth == 0: out.append(cur); cur = ''
        else: cur += ch
    out.append(cur); return out

def find_calls(src, name_re):
    """Every call 'X.sample(' (name_re matches the receiver and method) → (start, end, receiver, args)"""
    calls = []
    for m in re.finditer(name_re, src):
        i = m.end(); depth = 1; j = i
        while depth and j < len(src):
            if src[j] == '(': depth += 1
            elif src[j] == ')': depth -= 1
            j += 1
        calls.append((m.start(), j, m, split_top(src[i:j - 1])))
    return calls

def vertex_part(vsrc):
    """The vertex shader as plain functions dmv_main / dmv_main_z(dmv_in in, constant dmv_DescriptorSetBuffer0& d, uint vid, uint iid, uint bvert, uint binst) → dmv_out, with
    its structs; returns (text, outputs [(type, name, locn, flat)], inputs [(type, name, attribute index)], has_descriptor)"""
    cut = vsrc.find('\nvertex ')
    if cut < 0: raise Unsupported('vertex: no vertex function')
    head = vsrc[:cut]
    fns = {}
    for ep in ('main0', 'main0_z'):
        t, m = fn_text(vsrc, r'\nvertex\s+main0_out\s+%s\s*\(' % ep)
        if not t: raise Unsupported('vertex: no %s' % ep)
        fns[ep] = t
    text = head + '\n' + fns['main0'] + '\n' + fns['main0_z']
    outs = struct_body(text, 'main0_out')
    if outs is None: raise Unsupported('vertex: no output struct')
    outputs = []
    for ty, nm, locn, flat, at in strip_attrs(outs):
        if 'position' in at: continue
        if 'point_size' in at: continue
        if 'clip_distance' in at or 'render_target_array_index' in at or 'viewport_array_index' in at: raise Unsupported('vertex: output ' + at)
        if locn is None: raise Unsupported('vertex: output without a location: ' + nm)
        outputs.append((ty, nm, locn, flat))
    ins = struct_body(text, 'main0_in')
    inputs = []
    if ins is not None:
        for ty, nm, locn, flat, at in strip_attrs(ins):
            a = re.search(r'attribute\((\d+)\)', at)
            if not a or ty not in ('float4', 'int4', 'uint4'): raise Unsupported('vertex: input %s %s [[%s]]' % (ty, nm, at))
            inputs.append((ty, nm, int(a.group(1))))
    # the signatures: which parameters the two entry points take
    sigs = {}
    for ep in ('main0', 'main0_z'):
        m = re.search(r'vertex\s+main0_out\s+%s\s*\((.*?)\)\s*\n\{' % ep, fns[ep], re.S)
        sigs[ep] = params_of('(' + m.group(1) + ')')
    def plain_sig(ps):
        args = []
        for decl, at in ps:
            if at == 'stage_in': args.append(decl.replace('main0_in', 'dmv_in'))
            elif at.startswith('buffer('): args.append(decl)
            elif at == 'vertex_id': args.append(decl)
            elif at == 'instance_id': args.append(decl)
            elif at == 'base_vertex': args.append(decl)
            elif at == 'base_instance': args.append(decl)
            else: raise Unsupported('vertex: parameter [[%s]]' % at)
        return args
    callargs = {}
    for ep in ('main0', 'main0_z'):
        ca = []
        for decl, at in sigs[ep]:
            if at == 'stage_in': ca.append('in')
            elif at.startswith('buffer('): ca.append('d')
            elif at == 'vertex_id': ca.append('vid')
            elif at == 'instance_id': ca.append('iid')
            elif at == 'base_vertex': ca.append('bvert')
            elif at == 'base_instance': ca.append('binst')
        callargs[ep] = ca
    # strip stage attributes in the structs, rename, plain signatures
    text = re.sub(r'\s*\[\[(attribute\(\d+\)|position(, invariant)?|user\(locn\d+\)(, \w+)?|point_size|flat|center_no_perspective|centroid_perspective|centroid_no_perspective|sample_perspective|sample_no_perspective)\]\]', '', text)
    for ep in ('main0', 'main0_z'):
        text = re.sub(r'vertex\s+main0_out\s+%s\s*\((.*?)\)\s*\n\{' % ep, lambda m: 'static dmv_out dmv_%s(%s)\n{' % (ep, ', '.join(plain_sig(sigs[ep]))), text, count=1, flags=re.S)
    text = text.replace('main0_in', 'dmv_in').replace('main0_out', 'dmv_out').replace('spvDescriptorSetBuffer0', 'dmv_DescriptorSetBuffer0')
    text = re.sub(r'\b_(\d+)\b', r'v_\1', text)
    has_desc = 'dmv_DescriptorSetBuffer0' in text
    buf_idx = None
    for decl, at in sigs['main0']:
        if at.startswith('buffer('): buf_idx = int(at[7:-1])
    if ins is None: text = text.replace('struct dmv_out', 'struct dmv_in { float4 dm_unused; };\n\nstruct dmv_out', 1)
    return text, outputs, inputs, has_desc, buf_idx, callargs

def fragment_part(fsrc):
    """The fragment shader's main0 as a plain function dmf_main(main0_in in, constant spvDescriptorSetBuffer0& d, float4 gl_FragCoord, bool gl_FrontFacing, ushort dm_lane, thread bool& dm_kill);
    returns (text, outputs [(type, name, color)], inputs [(type, name, locn, flat)], has_descriptor, buffer index, call args)"""
    cut = fsrc.find('\nstruct main0_out_u\n')
    if cut >= 0: fsrc = fsrc[:cut + 1]
    t, m = fn_text(fsrc, r'\nfragment\s+main0_out\s+main0\s*\(')
    if not t: raise Unsupported('fragment: no main0')
    head = fsrc[:m.start() + 1]
    if 'discard_fragment' in head or '.sample(' in head or '.sample_compare(' in head or 'dfdx(' in head or 'dfdy(' in head or 'fwidth(' in head or '.gather(' in head:
        raise Unsupported('fragment: a helper function samples or discards')
    if '.sample_compare(' in t or '.gather_compare(' in t: raise Unsupported('fragment: sample_compare')   # a kernel's sample_compare takes no implicit LOD; gather has none and stays
    outs = struct_body(fsrc, 'main0_out')
    if outs is None: raise Unsupported('fragment: no output struct')
    outputs = []
    for ty, nm, locn, flat, at in strip_attrs(outs):
        c = re.search(r'^color\((\d+)\)$', at)
        if not c or ty not in ('float4', 'half4', 'int4', 'uint4', 'float', 'float2', 'float3', 'uint', 'uint2', 'uint3', 'int', 'int2', 'int3'): raise Unsupported('fragment: output %s %s [[%s]]' % (ty, nm, at))
        outputs.append((ty, nm, int(c.group(1))))
    ins = struct_body(fsrc, 'main0_in')
    inputs = []
    if ins is not None:
        for ty, nm, locn, flat, at in strip_attrs(ins):
            if locn is None or ty != 'float4': raise Unsupported('fragment: input %s %s [[%s]]' % (ty, nm, at))
            if 'color(' in at: raise Unsupported('fragment: colour input')
            inputs.append((ty, nm, locn, flat))
    sig = re.search(r'fragment\s+main0_out\s+main0\s*\((.*?)\)\s*\n\{', t, re.S)
    ps = params_of('(' + sig.group(1) + ')'); args = []; callargs = []; buf_idx = None
    for decl, at in ps:
        if at == 'stage_in': args.append(decl); callargs.append('in')
        elif at.startswith('buffer('): args.append(decl); callargs.append('d'); buf_idx = int(at[7:-1])
        elif at == 'position': args.append(decl); callargs.append('fc')
        elif at == 'front_facing': args.append(decl); callargs.append('front')
        else: raise Unsupported('fragment: parameter [[%s]]' % at)
    args += ['ushort dm_lane', 'thread bool& dm_kill']
    body = t[sig.end():]
    body = body.replace('discard_fragment();', 'dm_kill = true;')
    # texture member types of the descriptor set (for the sample rewrite)
    desc = struct_body(fsrc, 'spvDescriptorSetBuffer0') or ''
    ttype = {m.group(2): m.group(1) for m in re.finditer(r'(texture\w+(?:<[^>]*>)?)\s+(\w+)\s*\[\[id\(\d+\)\]\];', desc)}
    # samples: implicit LOD → explicit gradients over the quad
    out = []; pos = 0
    for start, end, m, args_ in find_calls(body, r'spvDescriptorSet0\.(\w+)\.sample\('):
        member = m.group(1); ty = ttype.get(member, '')
        out.append(body[pos:start])
        lod_opt = any(re.match(r'\s*(level|gradient2d|gradient3d|gradientcube|bias|min_lod_clamp)\(', x) for x in args_[2:])
        if not lod_opt:   # implicit LOD: the hardware takes it from the coordinate's derivatives over the quad; here the same gradients, explicit
            coord = args_[1].strip(); grad = None
            if ty.startswith('texture2d<') and len(args_) == 2: grad = 'gradient2d(dm_ddx(%s, dm_lane), dm_ddy(%s, dm_lane))' % (coord, coord)
            elif ty.startswith('texture2d_array<') and len(args_) == 3: grad = 'gradient2d(dm_ddx(%s, dm_lane), dm_ddy(%s, dm_lane))' % (coord, coord)
            elif ty.startswith('texture3d<') and len(args_) == 2: grad = 'gradient3d(dm_ddx(%s, dm_lane), dm_ddy(%s, dm_lane))' % (coord, coord)
            elif ty.startswith('texturecube<') and len(args_) == 2: grad = 'gradientcube(dm_ddx(%s, dm_lane), dm_ddy(%s, dm_lane))' % (coord, coord)
            if not grad: raise Unsupported('fragment: implicit-LOD sample of %s with %d arguments' % (ty or '?', len(args_)))
            out.append('spvDescriptorSet0.%s.sample(%s, %s)' % (member, ', '.join(x.strip() for x in args_), grad))
        else:
            extra = ','.join(args_[2:])
            if 'bias(' in extra: raise Unsupported('fragment: sample with bias')
            out.append(body[start:end])
        pos = end
    body = ''.join(out) + body[pos:]
    body = re.sub(r'\bdfdx\(', 'dm_ddx_(dm_lane, ', body); body = re.sub(r'\bdfdy\(', 'dm_ddy_(dm_lane, ', body); body = re.sub(r'\bfwidth\(', 'dm_fwidth_(dm_lane, ', body)
    text = head + re.sub(r'\s*\[\[(user\(locn\d+\)(, \w+)?|color\(\d+\)|flat|center_no_perspective|centroid_perspective|centroid_no_perspective|sample_perspective|sample_no_perspective)\]\]', '', '') \
        + 'static main0_out dmf_main(%s)\n{' % ', '.join(args) + body
    text = re.sub(r'\s*\[\[(user\(locn\d+\)(, \w+)?|color\(\d+\)|flat|center_no_perspective|centroid_perspective|centroid_no_perspective|sample_perspective|sample_no_perspective)\]\]', '', text)
    if ins is None: text = text.replace('struct main0_out', 'struct main0_in { float4 dm_unused; };\n\nstruct main0_out', 1)
    return text, outputs, inputs, 'spvDescriptorSetBuffer0' in head, buf_idx, callargs

HELPERS = '''
// Coarse derivatives over the 2x2 quad the kernel runs its threads as (lanes 0 1 / 2 3): the same values the hardware gives a fragment quad
template<typename T> static inline T dm_ddx(T v, ushort lane) { T o = quad_shuffle_xor(v, 1); return (lane & 1) ? v - o : o - v; }
template<typename T> static inline T dm_ddy(T v, ushort lane) { T o = quad_shuffle_xor(v, 2); return (lane & 2) ? v - o : o - v; }
template<typename T> static inline T dm_ddx_(ushort lane, T v) { return dm_ddx(v, lane); }
template<typename T> static inline T dm_ddy_(ushort lane, T v) { return dm_ddy(v, lane); }
template<typename T> static inline T dm_fwidth_(ushort lane, T v) { return abs(dm_ddx(v, lane)) + abs(dm_ddy(v, lane)); }
'''

PARAMS = '''
struct dm_kp {   // per draw (the host's kpass_encode writes it; nvn_mtl.m kp_params)
    float4 vp;             // Metal viewport x, y, width, height (height negative for a flipped viewport)
    float2 dr;             // depth range near, far
    int2 rect0;            // dispatch rectangle origin (pixels)
    int2 rect1;            // and its end (exclusive)
    uint nvert, prim, cull, front_ccw;   // vertex count (3-6), primitive 4 = triangles 5 = strip, cull 0 none 1 front 2 back, front-facing winding counter-clockwise (in window space, y down)
    uint zmode, out_mask, clear_mask, vid0;   // zmode 1: the main0 entry point (depth remapped) 0: main0_z; which colour outputs have a texture; which get the clear colour where no triangle covers; first vertex index
    uint iid, bvert, binst, pad;
    float4 clear[8];
%s};
'''

def kernel_text(vt, vouts, vins, vdesc, vbuf, vcall, ft, fouts, fins, fdesc, fbuf, fcall):
    tex = ''
    for ty, nm, c in fouts:
        base = {'float4': 'float', 'float3': 'float', 'float2': 'float', 'float': 'float', 'half4': 'half', 'uint4': 'uint', 'uint3': 'uint', 'uint2': 'uint', 'uint': 'uint', 'int4': 'int', 'int3': 'int', 'int2': 'int', 'int': 'int'}[ty]
        tex += '    texture2d<%s, access::write> c%d;\n' % (base, c)
    k = '#include <metal_stdlib>\n#include <simd/simd.h>\n\nusing namespace metal;\n' + HELPERS + '\n// ---- vertex shader ----\n' + vt.split('using namespace metal;\n', 1)[-1] \
        + '\n// ---- fragment shader ----\n' + ft.split('using namespace metal;\n', 1)[-1] + PARAMS % tex
    args = ['constant dm_kp& P [[buffer(16)]]', 'device const dmv_in* vin [[buffer(17)]]', 'uint2 tg [[threadgroup_position_in_grid]]', 'ushort t [[thread_index_in_threadgroup]]']
    if fdesc: args.insert(0, 'constant spvDescriptorSetBuffer0& fd [[buffer(%d)]]' % fbuf)
    if vdesc: args.insert(1 if fdesc else 0, 'constant dmv_DescriptorSetBuffer0& vd [[buffer(%d)]]' % (1 if fdesc and fbuf == vbuf else vbuf))
    VM = {'in': 'vin[i]', 'd': 'vd', 'vid': 'P.vid0 + i', 'iid': 'P.iid', 'bvert': 'P.bvert', 'binst': 'P.binst'}
    def vc(ep): return ', '.join(VM[a] for a in vcall[ep])
    FM = {'in': 'in', 'd': 'fd', 'fc': 'fc', 'front': 'front'}
    fc_ = ', '.join(FM[a] for a in fcall) + ', lane, kill'
    k += '''
kernel void dm_kpass(%s)
{
    ushort q = t >> 2, lane = t & 3;
    int2 pix = P.rect0 + int2(int(tg.x) * 8 + (q & 3) * 2 + (lane & 1), int(tg.y) * 8 + (q >> 2) * 2 + (lane >> 1));
    float2 pc = float2(pix) + 0.5;
    // the vertex stage, uniform over the dispatch (3-6 vertices)
    dmv_out V[6];
    for (uint i = 0; i < P.nvert; i++) V[i] = P.zmode ? dmv_main0(%s) : dmv_main0_z(%s);
    // window positions: Metal's viewport transform, y down
    float3 S[6]; float W[6];
    for (uint i = 0; i < P.nvert; i++) { float4 p = V[i].gl_Position; float iw = 1.0 / p.w;
        S[i] = float3(P.vp.x + (p.x * iw * 0.5 + 0.5) * P.vp.z, P.vp.y + (0.5 - p.y * iw * 0.5) * P.vp.w, P.dr.x + p.z * iw * (P.dr.y - P.dr.x)); W[i] = iw; }
    uint ntri = P.prim == 4 ? P.nvert / 3 : P.nvert - 2;
    bool hit = false, front = true; float3 bc = float3(1.0, 0.0, 0.0); uint i0 = 0, i1 = 1, i2 = 2; float z = 0.0, iw = 1.0;
    for (uint k = 0; k < ntri; k++) {
        uint a = P.prim == 4 ? 3 * k : k, b = a + 1, c = a + 2; if (P.prim != 4 && (k & 1)) { uint x = b; b = c; c = x; }
        float2 A = S[a].xy, B = S[b].xy, C = S[c].xy;
        float area = (B.x - A.x) * (C.y - A.y) - (B.y - A.y) * (C.x - A.x);   // > 0: clockwise on screen (y down)
        if (area == 0.0) continue;
        bool ccw = area < 0.0, isfront = ccw == (P.front_ccw != 0);
        if ((P.cull == 2 && !isfront) || (P.cull == 1 && isfront)) continue;
        float e0 = (B.x - A.x) * (pc.y - A.y) - (B.y - A.y) * (pc.x - A.x);   // edge AB, weight of C
        float e1 = (C.x - B.x) * (pc.y - B.y) - (C.y - B.y) * (pc.x - B.x);   // edge BC, weight of A
        float e2 = (A.x - C.x) * (pc.y - C.y) - (A.y - C.y) * (pc.x - C.x);   // edge CA, weight of B
        if (area < 0.0) { e0 = -e0; e1 = -e1; e2 = -e2; area = -area; float2 x = B; B = C; C = x; uint y = b; b = c; c = y; float t0 = e0; e0 = e2; e2 = t0; }
        // top-left rule: a pixel centre on an edge belongs to the triangle when the edge is a top edge (horizontal, pointing left in this orientation) or a left edge (pointing up)
        bool in0 = e0 > 0.0 || (e0 == 0.0 && ((B.y == A.y && B.x < A.x) || B.y < A.y));
        bool in1 = e1 > 0.0 || (e1 == 0.0 && ((C.y == B.y && C.x < B.x) || C.y < B.y));
        bool in2 = e2 > 0.0 || (e2 == 0.0 && ((A.y == C.y && A.x < C.x) || A.y < C.y));
        if (!(in0 && in1 && in2)) continue;
        float3 w = float3(e1, e2, e0) / area;   // weights of A, B, C
        float zz = w.x * S[a].z + w.y * S[b].z + w.z * S[c].z;
        if (zz < 0.0 || zz > 1.0) continue;   // depth clipping (exact for triangles whose vertices are all in range)
        hit = true; front = isfront; bc = w; i0 = a; i1 = b; i2 = c; z = zz; iw = w.x * W[a] + w.y
* W[b] + w.z * W[c];
        break;
    }
    // interpolation (perspective-correct: attribute / w summed, over 1 / w); a pixel no triangle covers takes the first triangle's weights (as a helper invocation would)
    float3 pw = bc * float3(W[i0], W[i1], W[i2]) / max(iw, 1e-30);
    main0_in in = {};
%s    float4 fc = float4(pc, z, iw);
    bool kill = false;
    main0_out o = dmf_main(%s);
    bool inside = hit && !kill && pix.x < P.rect1.x && pix.y < P.rect1.y;
    bool clear = !hit && pix.x < P.rect1.x && pix.y < P.rect1.y;
%s}
''' % (', '.join(args), vc('main0'), vc('main0_z'), interp_text(vouts, fins), fc_, write_text(fouts))
    return k

def interp_text(vouts, fins):
    by_locn = {locn: (ty, nm, flat) for ty, nm, locn, flat in vouts}
    s = ''
    for ty, nm, locn, flat in fins:
        v = by_locn.get(locn)
        if not v: s += '    in.%s = float4(0.0);\n' % nm; continue
        vt, vn, vflat = v
        if flat or vflat: s += '    in.%s = float4(V[i0].%s);\n' % (nm, vn)
        else: s += '    in.%s = float4(V[i0].%s) * pw.x + float4(V[i1].%s) * pw.y + float4(V[i2].%s) * pw.z;\n' % (nm, vn, vn, vn)
    return s

def write_text(fouts):
    s = ''
    for ty, nm, c in fouts:
        vec = {'float4': 'float4', 'float3': 'float4', 'float2': 'float4', 'float': 'float4', 'half4': 'half4', 'uint4': 'uint4', 'uint3': 'uint4', 'uint2': 'uint4', 'uint': 'uint4', 'int4': 'int4', 'int3': 'int4', 'int2': 'int4', 'int': 'int4'}[ty]
        val = 'o.%s' % nm if ty in ('float4', 'half4', 'uint4', 'int4') else '%s(o.%s)' % (vec, nm) if ty in ('float', 'uint', 'int') else '%s(o.%s, %s)' % (vec, nm, '0, 0' if ty.endswith('2') else '0')
        s += '    if (P.out_mask >> %d & 1) { if (inside) P.c%d.write(%s, uint2(pix)); else if (clear && (P.clear_mask >> %d & 1)) P.c%d.write(%s(P.clear[%d]), uint2(pix)); }\n' % (c, c, val, c, c, vec, c)
    return s

def make_pair(msl_dir, out_dir, vs, fs):
    name = '%s__%s_k' % (vs, fs)
    meta_path = os.path.join(out_dir, name + '.json')
    try:
        vsrc = open(os.path.join(msl_dir, vs + '.metal')).read(); fsrc = open(os.path.join(msl_dir, fs + '.metal')).read()
        vt, vouts, vins, vdesc, vbuf, vcall = vertex_part(vsrc)
        ft, fouts, fins, fdesc, fbuf, fcall = fragment_part(fsrc)
        k = kernel_text(vt, vouts, vins, vdesc, vbuf, vcall, ft, fouts, fins, fdesc, fbuf, fcall)
        msl = os.path.join(out_dir, name + '.metal'); open(msl, 'w').write(k)
        air = msl[:-6] + '.air'; lib = os.path.join(out_dir, name + '.metallib')
        r = subprocess.run(['xcrun', '-sdk', 'macosx', 'metal', '-c', '-O2', '-fpreserve-invariance', msl, '-o', air], capture_output=True, text=True)
        if r.returncode: raise Unsupported('compile: ' + r.stderr.strip().splitlines()[0][:300] if r.stderr.strip() else 'compile failed')
        subprocess.run(['xcrun', '-sdk', 'macosx', 'metallib', air, '-o', lib], check=True, capture_output=True)
        os.unlink(air)
        meta = {'vs': vs, 'fs': fs, 'vin': [[a, ty] for ty, nm, a in vins], 'vin_desc': vdesc, 'fs_desc': fdesc, 'vs_buffer': (1 if fdesc and fbuf == vbuf else vbuf) if vdesc else None,
                'fs_buffer': fbuf if fdesc else None, 'outputs': [c for ty, nm, c in fouts], 'tg': TG}
        json.dump(meta, open(meta_path, 'w')); return True, None
    except Unsupported as e:
        json.dump({'vs': vs, 'fs': fs, 'unsupported': str(e)}, open(meta_path, 'w')); return False, str(e)
    except Exception as e:
        json.dump({'vs': vs, 'fs': fs, 'unsupported': 'generator error: %r' % e}, open(meta_path, 'w')); return False, 'generator error: %r' % e

def main(argv):
    if len(argv) >= 4 and argv[1] == '--pairs':
        pairs = [tuple(l.split()[:2]) for l in open(argv[2]) if l.strip() and not l.startswith('#')]; msl_dir, out_dir = argv[3], argv[4]
    elif len(argv) >= 5 and (len(argv) - 3) % 2 == 0:
        msl_dir, out_dir = argv[1], argv[2]; pairs = list(zip(argv[3::2], argv[4::2]))
    else:
        print(__doc__); return 2
    os.makedirs(out_dir, exist_ok=True); ok = 0; bad = {}
    for vs, fs in pairs:
        good, why = make_pair(msl_dir, out_dir, vs, fs)
        if good: ok += 1
        else: bad[why] = bad.get(why, 0) + 1; print('%s %s: %s' % (vs, fs, why))
    print('%d of %d pairs made' % (ok, len(pairs)))
    for why, n in sorted(bad.items(), key=lambda x: -x[1]): print('  %4d %s' % (n, why))
    return 0

if __name__ == '__main__': sys.exit(main(sys.argv))
