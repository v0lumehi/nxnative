// Launcher: the settings screen shown before the game starts (front_ios.m dm_show_launcher). Its settings come from the app's dm/launcher.json, which build_ipa.sh writes for this game
// from dm/games/settings.tsv (dm/games/settings.py): each sets an environment variable the host reads when the game starts. A variable an env file set (Documents/env.txt, the bundle's
// dm/env.txt; main.m lists them in DM_ENV_FILE_KEYS) is shown but kept. Choices that differ from the game's default are kept in UserDefaults. Settings whose page is advanced are on the Advanced page, whose
// Reset to tested defaults forgets the choices there, so the game profile's defaults (the settings it was tested with) apply again. DM_LAUNCHER=0 in Documents/env.txt starts the
// game at once, as an app without launcher.json does
import SwiftUI
import UIKit
import os

private struct Setting: Decodable, Identifiable {
    let env, kind, label, note, def: String
    let page: String?   // main or advanced
    let options: [[String]]?   // choice: [value, label]
    let min, max, step: Double?   // range
    let on, off: String?   // toggle: the values the variable takes (1 / 0 when not given)
    var id: String { env }
    var advanced: Bool { page == "advanced" }
    var onValue: String { on ?? "1" }
    var offValue: String { off ?? "0" }
    func isDefault(_ v: String) -> Bool {   // a range compares as numbers (a slider writes 1.00 for 1.0)
        kind == "range" ? abs((Double(v) ?? .nan) - (Double(def) ?? .nan)) < 1e-6 : v == def
    }
    func accepts(_ v: String) -> Bool {   // a saved choice the game still offers
        switch kind {
        case "choice": return options?.contains { $0[0] == v } ?? false
        case "range": return Double(v) != nil
        case "toggle": return v == onValue || v == offValue
        default: return true
        }
    }
    enum CodingKeys: String, CodingKey { case env, kind, label, note, def = "default", page, options, min, max, step, on, off }
}
private struct SettingsFile: Decodable { let settings: [Setting] }

private func info(_ key: String) -> Any? { Bundle.main.object(forInfoDictionaryKey: key) }
private let defaults = UserDefaults.standard

private final class LauncherModel: ObservableObject {
    let settings: [Setting]
    let fromFile: Set<String>   // set by an env file: shown, not changed
    @Published var values: [String: String] = [:]

    init(_ settings: [Setting]) {
        self.settings = settings
        fromFile = Set((ProcessInfo.processInfo.environment["DM_ENV_FILE_KEYS"] ?? "").split(separator: " ").map(String.init))
        for s in settings {
            if fromFile.contains(s.env), let v = ProcessInfo.processInfo.environment[s.env] { values[s.env] = v; continue }
            let saved = defaults.string(forKey: "launcher." + s.env)
            values[s.env] = saved.flatMap { s.accepts($0) ? $0 : nil } ?? s.def   // a saved choice the game no longer offers: its default
        }
    }

    var main: [Setting] { settings.filter { !$0.advanced } }
    var advanced: [Setting] { settings.filter { $0.advanced } }
    var advancedChanged: Bool { advanced.contains { !fromFile.contains($0.env) && !$0.isDefault(values[$0.env] ?? $0.def) } }

    // Reset to tested defaults: the Advanced page's choices are forgotten and its rows show the game's defaults again (an env file's values stay)
    func resetAdvanced() {
        for s in advanced where !fromFile.contains(s.env) {
            defaults.removeObject(forKey: "launcher." + s.env)
            values[s.env] = s.def
        }
        fputs("launcher: advanced settings reset to the game's defaults\n", stderr)
    }

    func binding(_ s: Setting) -> Binding<String> { Binding(get: { self.values[s.env] ?? s.def }, set: { self.values[s.env] = $0 }) }

    // Before the game starts: every setting not set by an env file goes into the environment (DM_LANG replaces the packed language main.m set as a default). Only a choice that
    // differs from the game's default is stored: a setting the player left at its default follows the defaults of a later build (the settings it was tested with)
    func apply() {
        for s in settings {
            let v = values[s.env] ?? s.def
            if fromFile.contains(s.env) { fputs("launcher: \(s.env) kept at \(v) (env file)\n", stderr); continue }
            if s.isDefault(v) { defaults.removeObject(forKey: "launcher." + s.env) } else { defaults.set(v, forKey: "launcher." + s.env) }
            setenv(s.env, v, 1); fputs("launcher: \(s.env)=\(v)\(s.isDefault(v) ? "" : " (changed)")\n", stderr)
        }
    }
}

private struct SettingRow: View {
    let s: Setting
    @ObservedObject var m: LauncherModel

    private var locked: Bool { m.fromFile.contains(s.env) }
    private var note: String {
        locked ? (s.note.isEmpty ? "" : s.note + " · ") + "Set by an env file" : s.note
    }
    private var rangeValue: Binding<Double> {
        Binding(get: { Double(m.values[s.env] ?? s.def) ?? s.max ?? 1 },
                set: { m.values[s.env] = String(format: "%.2f", $0) })
    }
    private var percentage: String { "\(Int((rangeValue.wrappedValue * 100).rounded())) %" }

    private var settingLabel: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(s.label)
            if !note.isEmpty { Text(note).font(.footnote).foregroundStyle(.secondary) }
        }
    }

    var body: some View {
        Group {
            switch s.kind {
            case "choice":
                Picker(selection: m.binding(s)) {
                    ForEach(s.options ?? [], id: \.[0]) { Text($0[1]).tag($0[0]) }
                } label: {
                    settingLabel
                }
                .pickerStyle(.navigationLink)
            case "range":
                NavigationLink {
                    Form {
                        Section {
                            HStack {
                                Text(s.label)
                                Spacer()
                                Text(percentage).monospacedDigit().foregroundStyle(.secondary)
                            }
                            Slider(value: rangeValue, in: (s.min ?? 0)...(s.max ?? 1), step: s.step ?? 0.05)
                                .accessibilityLabel(s.label)
                                .accessibilityValue(percentage)
                                .disabled(locked)
                        } footer: {
                            if !note.isEmpty { Text(note) }
                        }
                    }
                    .contentMargins(.horizontal, 12, for: .scrollContent)
                    .navigationTitle(s.label)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar(.visible, for: .navigationBar)
                } label: {
                    HStack {
                        settingLabel
                        Spacer()
                        Text(percentage).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            default:
                Toggle(isOn: Binding(get: { (m.values[s.env] ?? s.def) == s.onValue }, set: { m.values[s.env] = $0 ? s.onValue : s.offValue })) {
                    settingLabel
                }
            }
        }
        .disabled(locked)
    }
}

private struct LauncherView: View {
    @ObservedObject var m: LauncherModel
    let play: () -> Void
    @State private var memory = os_proc_available_memory()

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                VStack(spacing: 16) {
                    if let icon = appIcon() {
                        Image(uiImage: icon).resizable().frame(width: 96, height: 96)
                            .clipShape(RoundedRectangle(cornerRadius: 22))
                            .accessibilityHidden(true)
                    }
                    Text((info("CFBundleDisplayName") as? String) ?? "Game")
                        .font(.title.weight(.bold)).multilineTextAlignment(.center)
                    Text("Version \((info("CFBundleShortVersionString") as? String) ?? "")")
                        .font(.callout).foregroundStyle(.secondary)
                    playButton
                }
                .padding(16)
                .frame(width: geometry.size.width / 3, height: geometry.size.height)
                NavigationStack {
                    List {
                        Section {
                            ForEach(m.main) { SettingRow(s: $0, m: m) }
                            if !m.advanced.isEmpty {
                                NavigationLink("Advanced") { AdvancedView(m: m) }
                            }
                        }
                        Section {
                            HStack {
                                Text("Memory available")
                                Spacer()
                                Text(ByteCountFormatter.string(fromByteCount: Int64(memory), countStyle: .memory)).monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .contentMargins(.horizontal, 12, for: .scrollContent)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar(.hidden, for: .navigationBar)
                }
                .frame(width: geometry.size.width * 2 / 3)
            }
        }
        .preferredColorScheme(.dark)
        .task {
            while !Task.isCancelled {
                memory = os_proc_available_memory()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    @ViewBuilder var playButton: some View {
        let button = Button(action: play) { Text("Play").font(.title3.weight(.semibold)).frame(maxWidth: 220) }.controlSize(.large)
        if #available(iOS 26.0, *) { button.buttonStyle(.glassProminent) } else { button.buttonStyle(.borderedProminent) }
    }

    private func appIcon() -> UIImage? {
        if let i = UIImage(named: "AppIcon") { return i }
        guard let icons = info("CFBundleIcons") as? [String: Any], let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let files = primary["CFBundleIconFiles"] as? [String], let last = files.last else { return nil }
        return UIImage(named: last)
    }
}

// The Advanced page: settings that trade latency, memory or heat for smoothness, and the action that brings back the ones the game was tested with
private struct AdvancedView: View {
    @ObservedObject var m: LauncherModel

    var body: some View {
        List {
            Section {
                ForEach(m.advanced) { SettingRow(s: $0, m: m) }
            }
            Section {
                Button("Reset to tested defaults") { m.resetAdvanced() }
                    .disabled(!m.advancedChanged)
            } footer: {
                Text("Brings back the settings this game was tested with.")
            }
        }
        .listStyle(.insetGrouped)
        .contentMargins(.horizontal, 12, for: .scrollContent)
        .navigationTitle("Advanced")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
    }
}

// Shows the launcher over the root view controller and calls done once the settings are in the environment; false (done is not called) when there is no launcher
@_cdecl("dm_show_launcher")
public func dmShowLauncher(_ viewController: UnsafeMutableRawPointer, _ done: @convention(c) () -> Void) -> Bool {
    if ProcessInfo.processInfo.environment["DM_LAUNCHER"] == "0" { fputs("launcher: off (DM_LAUNCHER=0)\n", stderr); return false }
    guard let url = Bundle.main.resourceURL?.appendingPathComponent("dm/launcher.json"), let data = try? Data(contentsOf: url) else { return false }
    guard let file = try? JSONDecoder().decode(SettingsFile.self, from: data), !file.settings.isEmpty else { fputs("[RED] launcher: dm/launcher.json cannot be read; starting the game\n", stderr); return false }
    let parent = Unmanaged<UIViewController>.fromOpaque(viewController).takeUnretainedValue()
    let model = LauncherModel(file.settings)
    var host: UIViewController?
    let view = LauncherView(m: model) {
        guard let h = host else { return }
        host = nil
        model.apply()
        h.dismiss(animated: false) { done() }
    }
    let h = UIHostingController(rootView: view)
    h.modalPresentationStyle = .fullScreen
    host = h
    parent.present(h, animated: false)
    fputs("launcher: \(file.settings.count) settings shown\n", stderr)
    return true
}
