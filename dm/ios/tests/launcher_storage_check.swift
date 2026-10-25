// The launcher's storage (Launcher.swift LauncherModel), run by test_launcher_storage.py in a booted iOS Simulator: only choices that differ from the game's default are
// stored, Reset to tested defaults clears the Advanced page's, an env file's values are kept. Argument: a launcher.json of Breath of the Wild (settings.py, GFXAPI=nvn)
import Foundation
@main struct Check {
    static func main() {
        var failed = 0
        func expect(_ c: Bool, _ what: String) { print((c ? "PASS " : "FAIL ") + what); if !c { failed += 1 } }
        let file = try! JSONDecoder().decode(SettingsFile.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        let d = UserDefaults.standard
        for k in d.dictionaryRepresentation().keys where k.hasPrefix("launcher.") { d.removeObject(forKey: k) }
        d.set("1", forKey: "launcher.DM_PRESENT_SNAP")   // stored by the old launcher, equal to the default
        d.set("30", forKey: "launcher.DM_FPS_TARGET")    // a changed choice on the first page
        d.set("0", forKey: "launcher.DM_PSO_MTL4")       // a changed choice on the Advanced page
        d.set("1", forKey: "launcher.DM_FPS_HOLD")       // a value the toggle does not take (on / off): the default
        setenv("DM_ENV_FILE_KEYS", "DM_METAL_HUD", 1); setenv("DM_METAL_HUD", "1", 1)   // set by Documents/env.txt
        let m = LauncherModel(file.settings)
        expect(m.values["DM_FPS_TARGET"] == "30" && m.values["DM_PSO_MTL4"] == "0" && m.values["DM_FPS_HOLD"] == "on" && m.values["DM_METAL_HUD"] == "1", "stored choices and the env file are read")
        expect(m.advancedChanged, "Reset is offered with a changed Advanced choice")
        m.values["DM_RENDER_SCALE"] = "1.00"   // the slider's format of the default
        m.apply()
        expect(d.string(forKey: "launcher.DM_PRESENT_SNAP") == nil, "a value equal to the default is not stored (and an old one is dropped)")
        expect(d.string(forKey: "launcher.DM_RENDER_SCALE") == nil && d.string(forKey: "launcher.DM_OPMODE") == nil && d.string(forKey: "launcher.DM_FPS_HOLD") == nil, "defaults are not stored")
        expect(d.string(forKey: "launcher.DM_FPS_TARGET") == "30" && d.string(forKey: "launcher.DM_PSO_MTL4") == "0", "changed choices are stored")
        expect(d.string(forKey: "launcher.DM_METAL_HUD") == nil && String(cString: getenv("DM_METAL_HUD")) == "1", "the env file's value is kept and not stored")
        expect(String(cString: getenv("DM_PSO_MTL4")) == "0" && String(cString: getenv("DM_PRESENT_SNAP")) == "1" && String(cString: getenv("DM_FPS_HOLD")) == "on", "the environment gets every value")
        m.resetAdvanced()
        expect(d.string(forKey: "launcher.DM_PSO_MTL4") == nil && m.values["DM_PSO_MTL4"] == "1", "Reset clears the Advanced choices and shows the defaults")
        expect(d.string(forKey: "launcher.DM_FPS_TARGET") == "30", "Reset leaves the first page")
        expect(m.values["DM_METAL_HUD"] == "1" && !m.advancedChanged, "Reset leaves the env file's value; nothing left to reset")
        print("launcher storage: \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
