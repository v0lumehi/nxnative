# Hades (0100535012974000): the rewriter's patches of this game's own builds. dm/tools/patch_nso.py loads every profile's patches.py and applies those of a module's build;
# CUTS, OBS and FRAME_STEP as described there ("Registered patches"). Hades has no frame step: its entry in FRAME_STEP only uses the state page for the output size stub
# and the wide view stubs
import struct
from nso_asm import ADRP, B, LDR_LIT, ADR, CBZ_X, CBZ_W, MOVZ_X16


# Wide view: Hades lays everything out on a logical 1920x1080 screen. The port of the PC mod Hephaistos (https://github.com/nbusseneau/hephaistos, MIT licence, Copyright (c) 2021
# Nicolas Busseneau) widens that screen to 1080 x the output's aspect (hor+), as its hex patches do on the PC engines (the viewport size, sgg::GUIConstants FULL_SCREEN and
# SCREEN_CENTER / NATIVE_CENTER, the width floats): here the logical width replaces the (1920, 1080) and (960, 540) vectors each translation unit's static initializer builds
# for those constants, the read-only 1920.0 that CalculateViewportForAspectRatio and seven other places load, and an integer (1920, 1080) pair. The Lua and SJSON half of Hephaistos is the RomFS overlay the NSP script
# writes (romfs_overlay.py beside this file); its Lua reads the logical width from the config option WindowWidth, which logical_options below sets.
# State page fields of these stubs (written by the first one, read by the rest): +0x80 float logical width, +0x84 float its half, +0x88 u32 logical width.
# The width is max(1920, 1080 x output width / output height) when the loader asks for the wide view (+0x4c = 1: WIDE_VIEW below; DM_ASPECT=bars clears it), else 1920,
# so the game keeps its own 16:9 layout with side bar art (sgg's CalculateViewportForAspectRatio, main+0x47c1b0). A narrower output (an iPad's 4:3) never gets here: the loader keeps 16:9
lw, lh, li = 0x80, 0x84, 0x88
# (1920.0, 1080.0) pairs: movz xN, #0x44f0, lsl #16 ... movk xN, #0x4487, lsl #48 (73: 70 static initializers and main+0x357f10, +0x40e338, +0x61d4c8)
full_screen = {8: '2499ac 249c88 24a1c0 24abf0 24b064 24b304 24b5a4 24b844 24bae4 24bd84 24c024 24c2b8 24c564 24c7e4 24ca4c 24d004 24d2a4 24d544 24d7d8 24e690 24eb74 '
           '25b004 25b594 25baa4 25c684 25cb54 25ce30 25db18 25dd94 25f368 2600a4 260318 260690 260d8c 260ff4 2631c4 2634a0 26375c 2639f0 26415c 26685c 267d18 '
           '268098 2685f4 268838 268db4 269958 269ba8 269e54 26a3c8 26a624 357f10 40e338 61d4c8',
        9: '24a474 24a910 24e36c 24ee18 25ac90 25b254 25bccc 260ab0 262c7c 263e40 2644bc 26622c 268320 268abc 269030 2692b0 2695f4 26a0a0',
        10: '26ab2c'}
# (960.0, 540.0) pairs: movz xN, #0x4470, lsl #16 ... movk xN, #0x4407, lsl #48 (71: 70 static initializers and one at run time, main+0x3e0c80). The other (960, y) vectors stay
screen_center = {8: '24af3c 24b1dc 24b47c 24b71c 24b9bc 24bc5c 24befc 24c43c 24c930 24cedc 24d17c 24d41c 24d6bc 268718 268c8c',
          9: '249870 249b70 24a090 24aac8 24c190 24e55c 25b47c 25c548 25ca38 25cd14 25da00 25dc78 25f244 2601e8 260c70 260eb8 2630a8 263380 2638c0 264014 267bfc '
             '269840 269d38 26a2b0 26a840',
          10: '24a358 24a7f4 24c6c0 24e24c 24ea3c 24ed00 25ab74 25aed0 25b13c 25b980 25bbb0 25ff80 260568 260994 262b50 263630 263d24 2643a8 26610c 266730 267f6c '
              '268200 2684d0 26899c 268f1c 26919c 2694d4 269a7c 269f84 26a500',
          22: '3e0c80'}
# ldr sN, [xM, #0xf5c]: the read-only 1920.0 at main+0x6a1f5c (CalculateViewportForAspectRatio at main+0x47c1e4 and seven others)
width_loads = ['0c5d4fbd 3e33b4', '005d4fbd 3f3440', '085d4fbd 416ef4', '085d4fbd 47c1e4', '485d4fbd 48e808', '485d4fbd 493b68', '015d4fbd 587f50', '285d4fbd 5f0f8c']

def wide_view(ctx):
    here, emit, fs_site, fs_put, S = ctx.here, ctx.emit, ctx.site, ctx.put, ctx.state
    # DT_INIT (main+0x30, before every static initializer) computes the logical width once; x9-x12 and s16 / s17 are free at its entry (no arguments)
    fs_site(0x30, 'ff4302d1')   # sub sp, sp, #0x90
    start = here()
    emit(LDR_LIT('x', 9, here(), S + 0x40))   # ldr x9, state+0x40: output width | height << 32 (0 = the game's 1280x720)
    emit(LDR_LIT('w', 11, here(), S + 0x4c))  # ldr w11, state+0x4c: the loader asks for the wide view
    emit(0x5280F00A)                          # mov w10, #1920
    store = here() + 4 * 9                    # past the two branches and the seven instructions of the wide width
    emit(CBZ_X(9, here(), store))             # cbz x9, store: the game's own size
    emit(CBZ_W(11, here(), store))            # cbz w11, store: no wide view
    for w in (0xD360FD2B,   # lsr x11, x9, #32         height
              0x2A0903E9,   # mov w9, w9               width
              0x5280870C,   # mov w12, #1080
              0x9B0C7D29,   # mul x9, x9, x12
              0x9ACB0929,   # udiv x9, x9, x11         1080 x width / height
              0x6B0A013F,   # cmp w9, w10
              0x1A8A812A):  # csel w10, w9, w10, hi    never below 1920
        emit(w)
    assert here() == store
    emit(ADR(11, here(), S + lw))             # adr x11, state+0x80
    for w in (0x1E230150,   # ucvtf s16, w10
              0x1E2C1011,   # fmov s17, #0.5
              0xBD000170,   # str s16, [x11]           +0x80 logical width
              0x1E310A10,   # fmul s16, s16, s17
              0xBD000570,   # str s16, [x11, #4]       +0x84 its half
              0xB900096A,   # str w10, [x11, #8]       +0x88 logical width (u32)
              0xD10243FF):  # sub sp, sp, #0x90        the original instruction
        emit(w)
    emit(B(here(), 0x34))
    fs_put(0x30, [B(0x30, start)], 'DT_INIT: logical screen width for the wide view (state page +0x80..+0x8b)')
    # every site: one instruction becomes a branch to "load the logical value from the state page; back"
    def site(off, orig, load, why):
        fs_site(off, orig); stub = here(); emit(load(here())); emit(B(here(), off + 4)); fs_put(off, [B(off, stub)], why)
    for table, imm, field, what in ((full_screen, 0x44F0, lw, 'FULL_SCREEN x = logical width'), (screen_center, 0x4470, lh, 'SCREEN_CENTER x = half the logical width')):
        for rd, offs in table.items():
            for o in offs.split():
                site(int(o, 16), MOVZ_X16(rd, imm).to_bytes(4, 'little').hex(), lambda pc, rd=rd, field=field: LDR_LIT('w', rd, pc, S + field), what)
    for e in width_loads:
        word, o = e.split(); rt = int.from_bytes(bytes.fromhex(word), 'little') & 31
        site(int(o, 16), word, lambda pc, rt=rt: LDR_LIT('s', rt, pc, S + lw), '1920.0 = logical width')
    site(0x262d54, '09f080d2', lambda pc: LDR_LIT('w', 9, pc, S + li), '(1920, 1080) x = logical width')   # mov x9, #0x780; movk x9, #0x438, lsl #32
    ctx.keys.update(WIDE_VIEW='1')

# The GUI layouts and animations in SJSON files place things at fixed positions of the 1920-wide screen. The wide view's RomFS overlay (romfs_overlay.py) marks the numbers
# Hephaistos recomputes for the wider screen instead of baking in one width: a marked number is the original less m x 1,000,000, where m = 1 moves it by half the extra width
# (Hephaistos' recenter), m = 2 by the whole extra width (anchored at the right edge; a width that spans the screen), and m = 3 holds -3,000,000 + 10,000 x a scale that grows
# with the width (overlays that cover the screen). The engine's SJSON parser (nflibs' nf_json_parser, its number at main+0x621020) decodes them where it stores the number it
# parsed (main+0x621604: str d8, [x19, w9, sxtw]) into the document, so every class's fields get the decoded value. x11 is free there and holds the flags meanwhile; no
# register from v16 up is used in that function. No number in the game's own SJSON files is below -500,000 (romfs_overlay.py checks)
def sjson_marks(ctx):
    here, emit, fs_site, fs_put, S = ctx.here, ctx.emit, ctx.site, ctx.put, ctx.state
    def BCOND(cond, pc, to): return 0x54000000 | ((((to - pc) >> 2) & 0x7FFFF) << 5) | cond
    while here() % 8: emit(0xD503201F)   # nop: the constants below are doubles
    K = here()
    for f in (-500000.0, 1000000.0, 960.0, 3000000.0, 0.0001, 1920.0): emit(int.from_bytes(struct.pack('<d', f)[:4], 'little')); emit(int.from_bytes(struct.pack('<d', f)[4:], 'little'))
    k = {n: K + 8 * i for i, n in enumerate(('mark', 'unit', 'c960', 'scale', 'scale_unit', 'c1920'))}
    off = 0x621604
    fs_site(off, '68ca29fc')
    start = here(); store, scale = start + 4 * 27, start + 4 * 18
    emit(0xD53B420B)                                  # mrs x11, nzcv
    emit(LDR_LIT('d', 16, here(), k['mark']))         # ldr d16, =-500000
    emit(0x1E702100)                                  # fcmp d8, d16
    emit(BCOND(5, here(), store))                     # b.pl store             not marked
    emit(LDR_LIT('d', 17, here(), k['unit']))         # ldr d17, =1000000
    for w in (0x1E711912,   # fdiv d18, d8, d17
              0x1E614252,   # fneg d18, d18
              0x1E644252,   # frintn d18, d18        m
              0x1E611013,   # fmov d19, #3.0
              0x1E732240):  # fcmp d18, d19
        emit(w)
    emit(BCOND(0, here(), scale))                     # b.eq scale
    emit(LDR_LIT('s', 20, here(), S + lh))            # ldr s20, state+0x84    half the logical width
    emit(0x1E22C294)                                  # fcvt d20, s20
    emit(LDR_LIT('d', 21, here(), k['c960']))         # ldr d21, =960
    for w in (0x1E753A94,   # fsub d20, d20, d21     the extra width's half
              0x1E712A94,   # fadd d20, d20, d17
              0x1F542248):  # fmadd d8, d18, d20, d8  original + m x the extra width's half
        emit(w)
    emit(B(here(), store))
    assert here() == scale
    emit(LDR_LIT('d', 20, here(), k['scale']))        # ldr d20, =3000000
    emit(0x1E742908)                                  # fadd d8, d8, d20
    emit(LDR_LIT('d', 20, here(), k['scale_unit']))   # ldr d20, =0.0001
    emit(0x1E740908)                                  # fmul d8, d8, d20       the scale
    emit(LDR_LIT('s', 20, here(), S + lw))            # ldr s20, state+0x80    logical width
    emit(0x1E22C294)                                  # fcvt d20, s20
    emit(0x1E740908)                                  # fmul d8, d8, d20
    emit(LDR_LIT('d', 20, here(), k['c1920']))        # ldr d20, =1920
    emit(0x1E741908)                                  # fdiv d8, d8, d20       x logical width / 1920
    assert here() == store
    emit(0xD51B420B)                                  # msr nzcv, x11
    emit(0xFC29CA68)                                  # str d8, [x19, w9, sxtw]   the original instruction
    emit(B(here(), off + 4))
    fs_put(off, [B(off, start)], 'SJSON number: decode the wide view\'s marked numbers')

# Hades sets its window size once at startup (main+0x2492b0: 1280x720 into the window settings at main+0x8ccd90, +0x8 and +0x130, docked and handheld alike), and The Forge
# makes the swap chain and the render targets from it, ignoring the Vulkan surface's extent. The stub replaces the movk of that pair: x9 = the host's output size (state page +0x40,
# DM_OUTPUT_SIZE; 0 = the game's 1280x720). At 2560x1440 the game renders the whole frame at that size (not an upscale)
def output_size(ctx):
    here, emit, fs_site, fs_put, FS_STATE_OFF = ctx.here, ctx.emit, ctx.site, ctx.put, ctx.state
    fs_site(0x2492e0, '095ac0f2')
    start = here(); emit(ADRP(9, here(), FS_STATE_OFF))
    for w in (0xf9402129,   # ldr x9,[x9,#0x40]      the host's size
              0xb5000069,   # cbnz x9,+3
              0xd280a009,   # mov x9,#0x500          the game's 1280x720
              0xf2c05a09):  # movk x9,#0x2d0,lsl #32
        emit(w)
    emit(B(here(), 0x2492e4))
    fs_put(0x2492e0, [B(0x2492e0, start)], 'window size = the host\'s output size (state page +0x40; 0 = 1280x720)')
    ctx.keys.update(OUTPUT_W='0x500', OUTPUT_H='0x2d0')

# The wide view's Lua reads the logical screen with GetConfigOptionValue: the config options WindowWidth / WindowHeight (main+0xeef300 / +0xeef2fc, zero and unused on the Switch,
# not saved in its profile) get the logical width and 1080 wherever the engine sets the options X / Y (main+0xeef118 / +0xeef11c) to the drawable's size: when it applies the
# profile's settings (main+0x273bc0, x9 free) and when the resolution changes (main+0x29a6b4, x20 free). The original store comes first; the register holds 0xeef000 at both
def logical_options(ctx):
    here, emit, fs_site, fs_put, S = ctx.here, ctx.emit, ctx.site, ctx.put, ctx.state
    for off, orig, base, tmp in ((0x273bc0, '0a1d01b9', 8, 9), (0x29a6b4, '541b01b9', 26, 20)):
        fs_site(off, orig); stub = here()
        emit(int.from_bytes(bytes.fromhex(orig), 'little'))       # the original store (Y, X)
        emit(LDR_LIT('w', tmp, here(), S + li))                   # ldr wT, state+0x88: logical width
        emit(0xB9030000 | (base << 5) | tmp)                      # str wT, [xB, #0x300]   WindowWidth
        emit(0x52808700 | tmp)                                    # mov wT, #1080
        emit(0xB902FC00 | (base << 5) | tmp)                      # str wT, [xB, #0x2fc]   WindowHeight
        emit(B(here(), off + 4))
        fs_put(off, [B(off, stub)], 'WindowWidth / WindowHeight = the logical screen, for the wide view\'s Lua')

def stubs(ctx):
    wide_view(ctx); sjson_marks(ctx); output_size(ctx); logical_options(ctx)

FRAME_STEP = {'d41357a3da356b09fa400b90f303b564': stubs}
