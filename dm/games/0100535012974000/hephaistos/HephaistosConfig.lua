-- nxnative: the screen is read when the game runs, not written here when patching. The engine's wide view stubs (dm/games/0100535012974000/patches.py) set the config
-- option WindowWidth to the logical width they widened the engine to (1080 x the output's aspect, or 1920 when the picture is 16:9 or the player chose the side bars)
-- and WindowHeight to 1080; without them both are 0 and nothing moves
function Hephaistos.ReadScreen()
  local w = GetConfigOptionValue({ Name = "WindowWidth" })
  Hephaistos.ScreenWidth = type(w) == "number" and w > Hephaistos.Default.ScreenWidth and w or Hephaistos.Default.ScreenWidth
  Hephaistos.ScreenHeight = Hephaistos.Default.ScreenHeight
  Hephaistos.ScreenCenterX = Hephaistos.ScreenWidth / 2
  Hephaistos.ScreenCenterY = Hephaistos.ScreenHeight / 2
  Hephaistos.ScaleFactorX = Hephaistos.ScreenWidth / Hephaistos.Default.ScreenWidth
  Hephaistos.ScaleFactorY = Hephaistos.ScreenHeight / Hephaistos.Default.ScreenHeight
  Hephaistos.ScaleFactor = math.max(Hephaistos.ScaleFactorX, Hephaistos.ScaleFactorY)
end
Hephaistos.ReadScreen()
Hephaistos.CenterHUD = false
