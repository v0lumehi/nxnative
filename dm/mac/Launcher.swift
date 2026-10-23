// Mac launcher: the window a packed Mac app (dm/mac/make_app.sh) shows before the game starts, as the iOS launcher does (dm/ios/Sources/Launcher.swift). It reads the game's
// paths and what its profile supports from Contents/Resources/game.json, keeps the choices in UserDefaults, sets the same environment switches as the scripts (DM_OUTPUT_SIZE /
// DM_RENDER_SCALE, DM_FPS_TARGET with DM_PRESENT_HZ and DM_PRESENT_LINK, DM_PRESENT_SHARPEN, DM_OPMODE, DM_LANG, DM_FULLSCREEN, DM_METAL_HUD, DM_ROMFS_OVERLAY) and replaces itself
// with the host (execv), so the game runs as this app (its Game Mode and Dock icon). Variables already set in the environment are kept
import AppKit
import SwiftUI

struct GameConfig: Decodable {
    let name: String
    let root: String            // the build folder (DM_ROOT)
    let modules: String         // the rewritten modules
    let romfs: String
    let msl: String
    let font: String
    let aoc: String?
    let shmap: String?          // the profile's shader map, copied into the app
    let fpsTarget: Int          // the profile's fps_target (0 = no frame step)
    let fpsMax: Int             // the profile's fps_max (above 60 = more frame rates)
    let outputSize: Bool        // the profile has output_size: the whole frame at a chosen size
    let renderPool: Bool        // the profile has render_pool: render scale above 1.0 (Breath of the Wild)
    let docked: Bool            // the profile's op_mode
    let languages: [String]
    let overlay: String?        // a preset replacement folder (DM_ROMFS_OVERLAY) until the player picks one in the launcher
    let overlayLabel: String?   // the note under the folder choice
}

let config: GameConfig? = {
    guard let url = Bundle.main.url(forResource: "game", withExtension: "json"), let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(GameConfig.self, from: data)
}()

private let defaults = UserDefaults.standard

func languageName(_ code: String) -> String {
    let name = Locale.current.localizedString(forIdentifier: code) ?? code
    return name.prefix(1).capitalized + name.dropFirst()
}

let screenHz = NSScreen.main?.maximumFramesPerSecond ?? 60

final class Settings: ObservableObject {
    @Published var resolution: String
    @Published var fps: Int
    @Published var sharpen: Double
    @Published var docked: Bool
    @Published var language: String
    @Published var fullscreen: Bool
    @Published var hud: Bool
    @Published var overlay: Bool
    @Published var overlayPath: String   // the folder whose files replace the game's (DM_ROMFS_OVERLAY); empty = none

    init(_ c: GameConfig) {
        resolution = defaults.string(forKey: "resolution") ?? "game"
        fps = defaults.object(forKey: "fps") as? Int ?? (c.fpsTarget != 0 ? c.fpsTarget : 60)
        sharpen = defaults.object(forKey: "sharpen") as? Double ?? 0
        docked = defaults.object(forKey: "docked") as? Bool ?? c.docked
        let saved = defaults.string(forKey: "language") ?? (c.languages.first(where: { $0.hasPrefix(Locale.current.language.languageCode?.identifier ?? "en") }) ?? c.languages.first ?? "en-US")
        language = c.languages.isEmpty || c.languages.contains(saved) ? saved : (c.languages.first ?? "en-US")
        fullscreen = defaults.object(forKey: "fullscreen") as? Bool ?? true
        hud = defaults.bool(forKey: "hud")
        overlay = defaults.object(forKey: "overlay") as? Bool ?? true
        overlayPath = defaults.string(forKey: "overlayPath") ?? (c.overlay ?? "")
    }

    func save() {
        for (k, v) in ["resolution": resolution, "fps": fps, "sharpen": sharpen, "docked": docked, "language": language, "fullscreen": fullscreen, "hud": hud, "overlay": overlay, "overlayPath": overlayPath] as [String: Any] {
            defaults.set(v, forKey: k)
        }
    }

    func environment(_ c: GameConfig) -> [String: String] {
        var e = ["DM_ROOT": c.root, "DM_ROMFS": c.romfs, "DM_MSL_DIR": c.msl, "DM_FONT_DIR": c.font, "DM_WINDOW": "1", "DM_AUDIO": "1",
                 "DM_SAVE": c.root + "/run/save", "DM_TEMP": c.root + "/run/temp", "DM_LANG": language, "DM_OPMODE": docked ? "1" : "0", "DM_METAL_HUD": hud ? "1" : "0"]
        if let a = c.aoc { e["DM_AOC_DIR"] = a }
        if let m = c.shmap { e["DM_NVN_SHMAP"] = m }
        if fullscreen { e["DM_FULLSCREEN"] = "1" }
        if sharpen > 0 { e["DM_PRESENT_SHARPEN"] = String(format: "%.2f", sharpen) }
        if resolution != "game" {
            if c.outputSize { e["DM_OUTPUT_SIZE"] = resolution }
            else if c.renderPool { e["DM_RENDER_SCALE"] = ["1080p": "1.2", "1440p": "1.6", "4k": "2.4"][resolution] ?? "1.0" }
        }
        if c.fpsTarget != 0 || c.fpsMax > 60 {
            e["DM_FPS_TARGET"] = String(fps)
            if fps > 60 { e["DM_PRESENT_HZ"] = String(fps); e["DM_PRESENT_LINK"] = "2" }
        }
        if overlay && !overlayPath.isEmpty && FileManager.default.fileExists(atPath: overlayPath) { e["DM_ROMFS_OVERLAY"] = overlayPath }
        return e
    }
}

func launch(_ c: GameConfig, _ s: Settings) -> String {
    let run = c.root + "/run"
    for d in ["save", "temp"] { try? FileManager.default.createDirectory(atPath: run + "/" + d, withIntermediateDirectories: true) }
    FileManager.default.changeCurrentDirectoryPath(run)
    for (k, v) in s.environment(c) where getenv(k) == nil { setenv(k, v, 1) }
    let log = run + "/log.txt", prev = run + "/log.prev.txt"
    try? FileManager.default.removeItem(atPath: prev)
    try? FileManager.default.moveItem(atPath: log, toPath: prev)
    let fd = open(log, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    if fd >= 0 { dup2(fd, STDERR_FILENO); close(fd) }
    let host = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/dmhost").path
    var argv: [UnsafeMutablePointer<CChar>?] = [strdup(host), strdup(c.modules), nil]
    execv(host, &argv)
    return "Could not start the game (\(String(cString: strerror(errno))))"
}

struct LauncherView: View {
    let c: GameConfig
    @StateObject var s: Settings
    @State private var error: String?

    var frameRates: [Int] {
        var r = [30, 60]
        if c.fpsMax > 60 || c.fpsTarget > 60 { if screenHz >= 120 { r.append(120) }; if screenHz >= 144 { r.append(144) } }
        return r
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 48, height: 48)
                Text(c.name).font(.title2.weight(.semibold))
                Spacer()
            }
            Form {
                Section("Picture") {
                    if c.outputSize || c.renderPool {
                        Picker("Resolution", selection: $s.resolution) {
                            Text("The game's own").tag("game")
                            Text("1080p").tag("1080p")
                            Text("1440p").tag("1440p")
                            Text("4K").tag("4k")
                        }
                    }
                    if c.fpsTarget != 0 || c.fpsMax > 60 {
                        Picker("Frame rate", selection: $s.fps) {
                            ForEach(frameRates, id: \.self) { Text("\($0) fps").tag($0) }
                        }
                    }
                    HStack {
                        Text("Sharpening")
                        Slider(value: $s.sharpen, in: 0...1, step: 0.1)
                        Text(s.sharpen == 0 ? "Off" : String(format: "%.1f", s.sharpen)).monospacedDigit().foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
                    }
                    Toggle("Full screen", isOn: $s.fullscreen)
                    Toggle("Performance HUD", isOn: $s.hud)
                }
                Section("Game") {
                    Picker("Console mode", selection: $s.docked) {
                        Text("Docked").tag(true)
                        Text("Handheld").tag(false)
                    }
                    if !c.languages.isEmpty {
                        Picker("Game language", selection: $s.language) {
                            ForEach(c.languages, id: \.self) { Text(languageName($0)).tag($0) }
                        }
                    }
                }
                Section {
                    HStack {
                        Text("Replacement files")
                        Spacer()
                        Text(s.overlayPath.isEmpty ? "None" : (s.overlayPath as NSString).lastPathComponent).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Button("Choose…", action: chooseOverlay)
                        if !s.overlayPath.isEmpty { Button("Remove") { s.overlayPath = "" } }
                    }
                    if !s.overlayPath.isEmpty { Toggle("Use them", isOn: $s.overlay) }
                } footer: {
                    Text(c.overlayLabel ?? "A folder laid out like the game's files (Content/…); its files replace the game's by path, e.g. assets from the PC version you own.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            if let e = error { Text(e).foregroundStyle(.red).font(.callout) }
            Button(action: play) { Text("Play").font(.title3.weight(.semibold)).frame(maxWidth: .infinity) }
                .controlSize(.large).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
        }
        .padding(20)
        .frame(width: 460)
    }

    func chooseOverlay() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = false
        p.message = "Choose a folder whose files replace the game's (laid out like its files: Content/…)"
        if p.runModal() == .OK, let url = p.url { s.overlayPath = url.path; s.overlay = true }
    }

    func play() {
        s.save()
        error = launch(c, s)
    }
}

@main
struct GameLauncher: App {
    var body: some Scene {
        WindowGroup(config?.name ?? "Game") {
            if let c = config { LauncherView(c: c, s: Settings(c)) } else { Text("Contents/Resources/game.json is missing or unreadable").padding(40) }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}
