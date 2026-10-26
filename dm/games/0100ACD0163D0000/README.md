# Batman: Arkham Knight (`0100ACD0163D0000`)

Update 1.0.5 (v327680) over the base game (the base NSP is 7 MB; the update holds the whole game, 26.9 GB), SDK 14.3.0 (its own `sdk` build). Part of Batman: Arkham Trilogy. Rocksteady's Unreal Engine 3: loose cooked packages (`BmGame/CookedSwitch/*.xxx`, Oodle-compressed chunks), texture caches (`*.tfc`), NVN, Wwise sound, CRI USM movies and Scaleform GFx menus. Modules `main` and `sdk`. GitHub issue #115.

Status: **in bring-up, not playable.** On the Mac the game boots, plays its logo movies (WB Games and the others, at 30 fps), shows its first menus (the language prompt, the legal text with "Continue") and the title screen with Batman in the rain behind the logo; but the picture is wrong: the first menu is white behind its UI, the title is washed out under light grey Scaleform panels, and after A on the title the whole screen stays white ([Open](#open)). About 2.4 GB resident with 1.4 GB of Metal allocations and an Unreal heap of 1.75 GB at the title. Not tried on an iPhone.

## What it needs

| Setting | Where | Why |
|---|---|---|
| FMallocBinned3 construction cut (`main+0x192ec14`: `b main+0x192fea4`) | [`patches.py`](patches.py), `dm/host/hle_uemalloc.c` (layout `UE3`) | its allocator reserves 1 GB + 37 GB of address regions, which failed (0x1803); the host allocator runs in its place: [Unreal's FMallocBinned3 replaced by the host allocator](../../../docs/reference/memory.md#unreals-fmallocbinned3-replaced-by-the-host-allocator) |
| `shader_key_skip 0x7d0+0x18` | [`game.tsv`](game.tsv) | the game shares control sections among shaders that differ only in GLSLC's hash: [Control sections shared among shaders that differ only in their hash](../../../docs/reference/shaders.md#control-sections-shared-among-shaders-that-differ-only-in-their-hash) |
| `shader_groups GlobalShaderCache=global CombinedShaderCache=material` | `game.tsv` | the two Unreal Engine 3 shader caches: [Unreal Engine 3 shader caches](../../../docs/reference/shaders.md#unreal-engine-3-shader-caches-oodle-compressed-packages) |
| Engage's 5 GB block: `mem_reserve 0x140000000`, `mem_alias 0x118000000`, `mem_stack 0x10000000`, `app_pool 0xCD500000`, `sys_resource 0x2000000` | `game.tsv` | the provisional profile's guess (virtual address memory, no heap); with the host allocator the alias region holds only the engine's own maps |
| `tex_flush_upload on`, `tex_dirty_upload on` | `game.tsv` | the game fills its textures with the CPU and flushes most of them never; without the keys the colour-grading LUT and other streamed textures stayed empty and the tone-mapped scene black: [CPU writes with no flush, caught by page protection](../../../docs/reference/nvn-objects.md#cpu-writes-with-no-flush-caught-by-page-protection-tex_dirty_upload) |
| `pad_layout full` | `game.tsv` | a 3D game |

## Memory

- **Resolved: `err::ShowError Result=0x1803`, then `0xe03` and a crash at `main+0xb2dae8` during the static constructors.** The FMalloc getter (`main+0x192eb30`) constructs a static FMallocBinned3 (`main+0x51818c0`) inline on the first allocation: `AllocateAddressRegion` of 1 GB (`main+0x192eee8`, its small-block metadata), then 37 GB (`main+0x192fe50`, 74 pools of 512 MB). The cut jumps from the guard over the construction to the guard's release; the host has put its allocator's vtable in the object before any guest code runs. Unreal Engine 3's FMalloc takes 32-bit sizes and alignments; slots in `hle_uemalloc.c` (layout `UE3`), named through the thread-safe proxy's vtable (`main+0x3450158`). Nothing outside the allocator reads its pool base (`main+0x3fd1088`).
- The SDK 14.3.0 build's AddressRegionManager has the 1 GB node area (`sdk+0x12d8a0`: `mov w8/w9, #0x3fe00000` at `+0x12d8b0` / `+0x12d94c`) and aligns regions of 1 GB and more to 1 GB (`VammManager::AllocateAddressRegion`, `sdk+0x12d9b0`; the `mov w10, #0x40000000` at `+0x12daac`). Neither is cut: with the host allocator the game asks for no region that needs it so far.
- At the title: about 2.4 GB resident, 1.4 GB of Metal allocations, the Unreal heap at 1.75 GB.

## Files and shaders

- 4,093 cooked packages (`.xxx`, 19 GB): an uncompressed summary in Rocksteady's own serialization, then compressed chunks (tag `0x9E2A83C1`, 128 KB blocks, Oodle Mermaid). The game's `OodleLZ_Decompress` is `main+0x8f8250`, found by its name string.
- Shaders: `GlobalShaderCache-Switch.bin` (magic `BMSG`, stored whole) and `CombinedShaderCache-Switch.xxx` (29 MB, 136 MB decoded); no other package holds any. 24,721 records, 22,024 keys with `shader_key_skip` (2,629 vertex, 19,269 pixel, 124 compute, 2 geometry), all built for the Mac (28 minutes with 4 workers). A boot through the menus to the title reports no shader missing from the map.
- Movies: CRI USM (`BmGame/Movies`, 7.5 GB), decoded by the game's own CRI threads (`CRI MPV Worker`); the logo movies play.

## Rendering

- The title screen renders a 3D scene (the deferred G-buffer at 1440×812: scene colour RG11B10F, normals RGB10A2, two RGBA8 targets), tiled lighting and post-processing in compute shaders (subgroup votes, ballots and shuffles, threadgroup atomics), a tone-mapping compute pass (1×1 R16F eye adaptation, a 16³ colour-grading LUT in a 256×16 RGBA8 target), a copy to the 1920×1080 target (`f93e9daa6c80f2c2`, with gamma and fade constants) and Scaleform's UI (`648ee7c01ac61562` + `45c7c510cd31e73a`).
- **Resolved: the tone-mapped scene was black.** Its colour-grading LUT (a 256×16 RGBA8 texture), like the other textures the game fills with the CPU, stayed empty until `tex_flush_upload` and `tex_dirty_upload` (with the first alone it still read zeros). With both, the title shows Batman; the scene colour then reaches 2.6–3.9 (RG11B10F), the 1×1 R16F eye adaptation reads 0.77 and the tone-mapped image is dark (mean 0.02).

## Mac routes

- The work folder's `run/boot.sh <log> [seconds] [VAR=value …]` runs the game under the shared `measure.lock` (no window unless `DM_WINDOW=1`); `run/ctl.sh` appends `DM_CTL` lines. From an empty save: `DM_KEYS=f1450:A,f1800:A,f2000:A` goes through the language prompt (white), the legal text and the title screen; the title shows from about frame 1900, and frame 2020 on is white after the third A. Frame numbers drift with load by a few dozen frames.

## Found on this game

General changes first needed here; each applies to every game:

- **The NSP script converts NSZ files with a standalone `nsz` executable on PATH** when the Python running it has no `nsz` module ([docs/development.md](../../../docs/development.md)).
- **Unreal Engine 3 shader caches in the shader split** (`shader_split.py` `ue3_package`, `ue3_records`; `profile_guess.py` `ue3`): [Unreal Engine 3 shader caches (Oodle-compressed packages)](../../../docs/reference/shaders.md#unreal-engine-3-shader-caches-oodle-compressed-packages).
- **Profile key `shader_key_skip`** (`hle_nvn.c` `keys_hash`, `shader_split.py` `key_ctl`): [Control sections shared among shaders that differ only in their hash](../../../docs/reference/shaders.md#control-sections-shared-among-shaders-that-differ-only-in-their-hash).
- **Unreal Engine 3's FMalloc on the host allocator** (layout `UE3`, a cut that is a branch): [Unreal's FMallocBinned3 replaced by the host allocator](../../../docs/reference/memory.md#unreals-fmallocbinned3-replaced-by-the-host-allocator).

## Open

- **White and light grey layers over the menus and the title (current).** Found so far:
  - The first menu (the prompt with "Ⓐ Select"; it shows on every boot) starts with a full-screen canvas quad (`e3a4f9e6b5d56436` + `fdb9c6049fe4ae94`) that samples a 4×4 white texture (Unreal's default white texture, created at boot) with vertex colour (1, 1, 1, 0) and blending off, so it paints the screen white; the menu's own text does not show on it. What it should show instead (a movie or scene texture that is not ready, or a different state) is not found.
  - Scaleform's shapes (`97dbfa4e3b5f2e3b` + `45c7c510cd31e73a`, batched: the batch index in the second vertex attribute's z picks four uniform rows per shape) have white vertex colours and colour transforms of (1, 1, 1, α) and (0, 0, 0, 0), α 0.2 on the first menu and 0.7 / 0.4 / 0.3 on the title; the same values at frames 2050 and 2450, so they are not an animation caught midway. Drawn with straight alpha blending, they cover the title in light grey; whether the game means them so or reads a state the host answers differently is not settled. Replacing the pixel shader with one that outputs each varying confirmed that the shader reads what the uniforms hold.
  - Ruled out: Metal fast math (all 22,024 shaders rebuilt with `-fno-fast-math`: the same white), the deferred uniform updates (`DM_NVN_UB_DEFER=0`: the same), stencil masks (every one of these draws has the stencil test off and all colour channels on). Eden (a yuzu-line emulator on MoltenVK, on the same Mac) shows the same white, so the cause may be common to both rather than this host's NVN layer.
- **An intermittent stall at the menus** (some runs, with or without sound and window): the main thread waits on an Unreal FEvent (an `nn::os` LightEvent, `main+0xbdd9f4`), the rendering thread in `TimedWaitLightEvent`, and presents stop around frame 1200–1800. With `DM_PROBE` on the wait the timing changes and it did not occur. Not found yet.
- **A rare crash** at `main+0x2031740` (sig 11, a wild pointer, `lr=main+0xeadc0`), once in about 30 boots.
- **A window that loses focus pauses the game** (`oe focus state → 2`, the game sets focus handling mode 1): Mac runs driven by `DM_CTL` should run without a window.
- **iPhone:** not built. Memory needs checking first (2.4 GB resident and a 1.75 GB Unreal heap at the title); the shader libraries for iOS are not built.
- Arkham City (`01003F00163CE000`) and Arkham Asylum (`0100E870163CA000`), also asked for in #115, are not started.
