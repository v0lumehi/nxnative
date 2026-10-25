# Batman: Arkham Knight (0100ACD0163D0000): the rewriter's patches of this game's own builds. dm/tools/patch_nso.py loads every profile's patches.py and applies those of a module's NSO build ID;
# CUTS, OBS and FRAME_STEP as described there ("Registered patches"). Patches of Nintendo SDK module builds are in dm/tools/sdk_patches.py
CUTS = {
  # Batman: Arkham Knight 1.0.5 (v327680) main: Rocksteady's Unreal Engine 3 carries an FMallocBinned3, a static object (main+0x51818c0) built inline in its guarded getter (main+0x192eb30) on the
  # first allocation, during the static constructors. The construction reserves a 1 GB address region (main+0x192eee8) and then 37 GB for its 74 pools of 512 MB (main+0x192fe50), which no alias
  # region of the host's holds (AllocateAddressRegion failed with 0x1803, err::ShowError, then a crash at main+0xb2dae8). The first instruction after the guard is taken jumps past the construction to
  # the guard's release (main+0x192fea4), so the object keeps the vtable the host put in it before any guest code ran: Unreal's allocator on a host malloc zone (dm/host/hle_uemalloc.c, layout UE3)
  'feae83dc9e9fb34c77d0a62f1fa9ae9f': [
    (0x192ec14, '68cb0090', 'a4040014', 'FMalloc getter: adrp x8 (start of the inline FMallocBinned3 construction) → b 0x192fea4 (the guard release); the host allocator\'s vtable is already in the object'),
  ],
}
