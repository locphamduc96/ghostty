import AppKit
import GhosttyKit
import SwiftUI
import UniformTypeIdentifiers

/// What the Background Video panel sets, kept in its own config file. It is
/// loaded after every other config file so the panel always wins over the
/// same options set elsewhere.
enum BackgroundVideoSettings {
    struct Values {
        /// `nil` writes an empty value, which turns the video off even if
        /// another config file sets one.
        var source: String?
        var opacity: Double
        var blur: Double
        var volume: Double
        var playInBackground: Bool
        var maxFps: Int
    }

    static var configURL: URL {
        let configHome = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
            .map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        return configHome.appendingPathComponent("ghostty/background-video.conf")
    }

    static func load(into config: ghostty_config_t) {
        let path = configURL.path
        guard FileManager.default.fileExists(atPath: path) else { return }
        ghostty_config_load_file(config, path)
    }

    static func save(_ values: Values) throws {
        let source = values.source?.components(separatedBy: .newlines).joined() ?? ""
        let contents = """
            # Written by View > Background Video… in Ghostty. Loaded after all
            # other config files, so it overrides these options set elsewhere.
            background-video = \(source)
            background-video-opacity = \(String(format: "%.2f", values.opacity))
            background-video-blur = \(String(format: "%.1f", values.blur))
            background-video-volume = \(String(format: "%.2f", values.volume))
            background-video-play-in-background = \(values.playInBackground)
            background-video-max-fps = \(values.maxFps)

            """
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try contents.write(to: configURL, atomically: true, encoding: .utf8)
    }
}

/// View > Background Video… (Cmd+Shift+B): a floating panel to pick the
/// video and tune it while watching the terminal.
final class BackgroundVideoPanel: NSObject, NSMenuItemValidation {
    static let shared = BackgroundVideoPanel()

    private let model = BackgroundVideoPanelModel()
    private var panel: NSPanel?

    static func installMenuItem(in menu: NSMenu?) {
        guard let menu else { return }
        let item = NSMenuItem(
            title: "Background Video…",
            action: #selector(show(_:)),
            keyEquivalent: "b")
        item.keyEquivalentModifierMask = [.command, .shift]
        item.target = shared

        // Pausing is something to do while working, so it also gets a menu
        // item with a shortcut, not only the button in the panel.
        let pauseItem = NSMenuItem(
            title: "Pause Background Video",
            action: #selector(togglePause(_:)),
            keyEquivalent: "b")
        pauseItem.keyEquivalentModifierMask = [.command, .option]
        pauseItem.target = shared

        menu.addItem(.separator())
        menu.addItem(item)
        menu.addItem(pauseItem)
    }

    @objc func togglePause(_ sender: Any?) {
        model.togglePause()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(togglePause(_:)) else { return true }
        let player = BackgroundVideoPlayer.shared
        menuItem.title = player.isPaused ? "Resume Background Video" : "Pause Background Video"
        return player.source != nil
    }

    @objc func show(_ sender: Any?) {
        if panel?.isVisible != true, let config = (NSApp.delegate as? AppDelegate)?.ghostty.config {
            model.reset(from: config)
        }
        reveal()
    }

    /// Brings the panel forward without reloading its values, e.g. to show
    /// an error for the video that was just picked.
    func reveal() {
        let panel = self.panel ?? makePanel()
        panel.makeKeyAndOrderFront(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false)
        panel.title = "Background Video"
        panel.isFloatingPanel = true
        panel.isReleasedWhenClosed = false
        panel.contentViewController = NSHostingController(rootView: BackgroundVideoPanelView(model: model))
        panel.center()
        self.panel = panel
        return panel
    }
}

final class BackgroundVideoPanelModel: ObservableObject {
    @Published var link = ""
    @Published var error: String?

    @Published var opacity = 0.3 {
        didSet { tuningDidChange() }
    }

    @Published var blur = 2.0 {
        didSet { tuningDidChange() }
    }

    @Published var volume = 0.0 {
        didSet { tuningDidChange() }
    }

    @Published var playInBackground = false {
        didSet { tuningDidChange() }
    }

    /// 30 or 60, the choices the panel offers.
    @Published var maxFps = 60 {
        didSet { tuningDidChange() }
    }

    /// The saved video, as opposed to `link`, which may still be being typed.
    private var source: String?
    private var pendingSave: DispatchWorkItem?
    private var isResetting = false

    /// Writing the config and reloading it for every slider tick would be
    /// wasteful, so sliders preview live and save once they settle.
    private static let saveDelay: TimeInterval = 0.3

    func reset(from config: Ghostty.Config) {
        isResetting = true
        defer { isResetting = false }
        source = config.backgroundVideo
        link = source ?? ""
        opacity = config.backgroundVideoOpacity
        blur = config.backgroundVideoBlur
        volume = config.backgroundVideoVolume
        playInBackground = config.backgroundVideoPlayInBackground
        maxFps = config.backgroundVideoMaxFps <= 30 ? 30 : 60
        error = nil
    }

    func togglePause() {
        let player = BackgroundVideoPlayer.shared
        player.setPaused(!player.isPaused)
    }

    func play() {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        setSource(trimmed.isEmpty ? nil : trimmed)
    }

    func turnOff() {
        setSource(nil)
    }

    func chooseFile() {
        let openPanel = NSOpenPanel()
        openPanel.title = "Choose a Background Video"
        openPanel.allowedContentTypes = [.movie]
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        guard openPanel.runModal() == .OK, let url = openPanel.url else { return }
        link = url.path
        play()
    }

    private func setSource(_ newSource: String?) {
        error = nil
        if let newSource, newSource != BackgroundVideoPlayer.shared.source {
            BackgroundVideoPlayer.shared.onNextFailure(of: newSource) { [weak self] message in
                self?.error = message
                BackgroundVideoPanel.shared.reveal()
            }
        }
        source = newSource
        save()
    }

    private func tuningDidChange() {
        guard !isResetting else { return }
        BackgroundVideoPlayer.shared.preview(opacity: opacity, blurRadius: blur)
        BackgroundVideoPlayer.shared.setVolume(volume)
        BackgroundVideoPlayer.shared.setPlaysInBackground(playInBackground)
        BackgroundVideoPlayer.shared.setMaxFps(maxFps)

        pendingSave?.cancel()
        let save = DispatchWorkItem { [weak self] in self?.save() }
        pendingSave = save
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.saveDelay, execute: save)
    }

    private func save() {
        pendingSave?.cancel()
        pendingSave = nil
        do {
            try BackgroundVideoSettings.save(.init(
                source: source,
                opacity: opacity,
                blur: blur,
                volume: volume,
                playInBackground: playInBackground,
                maxFps: maxFps))
        } catch {
            self.error = "Could not save \(BackgroundVideoSettings.configURL.path): \(error.localizedDescription)"
            return
        }
        (NSApp.delegate as? AppDelegate)?.reloadConfig(nil)
    }
}

struct BackgroundVideoPanelView: View {
    @ObservedObject var model: BackgroundVideoPanelModel
    @ObservedObject private var player = BackgroundVideoPlayer.shared
    @ObservedObject private var login = BackgroundVideoLogin.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("YouTube link, video link or file path", text: $model.link)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button("Choose File…") { model.chooseFile() }
                Button {
                    model.togglePause()
                } label: {
                    Label(
                        player.isPaused ? "Resume" : "Pause",
                        systemImage: player.isPaused ? "play.fill" : "pause.fill")
                }
                .disabled(player.source == nil)
                Spacer()
                Button("Turn Off") { model.turnOff() }
                Button("Play") { model.play() }
                    .keyboardShortcut(.defaultAction)
            }

            if let error = model.error {
                Text(error)
                    .font(.callout)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                sliderRow("Dim", value: $model.opacity, in: 0...1, label: percent(model.opacity))
                sliderRow("Blur", value: $model.blur, in: 0...20, label: String(format: "%.1f", model.blur))
                sliderRow(
                    "Volume",
                    value: $model.volume,
                    in: 0...1,
                    label: model.volume > 0 ? percent(model.volume) : "Off")
                GridRow {
                    Text("Frame rate")
                    Picker("Frame rate", selection: $model.maxFps) {
                        Text("30 fps").tag(30)
                        Text("60 fps").tag(60)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .help("The highest frame rate to use for web links. Local files play at their own.")
                    Text("")
                }
            }

            Toggle("Keep playing in background", isOn: $model.playInBackground)
                .help("Don't pause the video while the windows are covered or minimized.")

            Divider()

            HStack {
                Text("YouTube account")
                Text(login.isSignedIn ? "Signed in" : "Not signed in")
                    .foregroundColor(.secondary)
                Spacer()
                if login.isSignedIn {
                    Button("Sign Out") { login.signOut() }
                } else {
                    Button("Sign In…") { login.show() }
                }
            }
            .help("YouTube sometimes asks yt-dlp to sign in to prove it is not a bot.")
        }
        .padding(16)
        .frame(width: 440)
    }

    private func sliderRow(
        _ title: String,
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        label: String
    ) -> some View {
        GridRow {
            Text(title)
            Slider(value: value, in: range)
            Text(label)
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)
        }
    }

    private func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded())) %"
    }
}
