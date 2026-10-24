-- The following `Import` statement must be added to `RoomManager.lua` in order
-- for the mod to be properly loaded. This should be done automatically by
-- Hephaistos or by Mod Importer.
-- Import "../Mods/Hephaistos/Hephaistos.lua"

if not ModUtil then
  -- Hephaistos table
  -- Will hold all mod variables and functions
  Hephaistos = {}
  SaveIgnores.Hephaistos = true
else
  -- If ModUtil is installed, register Hephaistos with ModUtil
  -- ModUtil takes care of handling the Hephaistos table and save ignores
  ModUtil.Mod.Register("Hephaistos")
end

-- Default screen values as loaded from the save file, coming from `UIData.lua`
Hephaistos.Default = {
  ScreenWidth = ScreenWidth,
  ScreenHeight = ScreenHeight,
  ScreenCenterX = ScreenCenterX,
  ScreenCenterY = ScreenCenterY,
}

-- New screen values, read from the engine (HephaistosConfig.lua; again before each load, see HooksInit.lua)
Import "../Mods/Hephaistos/HephaistosConfig.lua"

-- Helper functions
Import "../Mods/Hephaistos/Helpers.lua"

-- Actual Hades modding happens here
Import "../Mods/Hephaistos/HooksInit.lua"
Import "../Mods/Hephaistos/LuaData.lua"
Import "../Mods/Hephaistos/Camera.lua"
Import "../Mods/Hephaistos/GUIComponents.lua"
Import "../Mods/Hephaistos/HooksRegister.lua"
