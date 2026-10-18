import AppKit
import AVFoundation
import CoreImage
import OSLog

/// Plays the `background-video` config behind terminal windows.
///
/// A single player is shared by every window. Each window only adds its own
/// `AVPlayerLayer`, so many tabs still decode one stream and play one audio
/// track. Page URLs (YouTube and the like) are resolved to a direct stream
/// with `yt-dlp`.
final class BackgroundVideoPlayer {
    static let shared = BackgroundVideoPlayer()

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier!,
        category: String(describing: BackgroundVideoPlayer.self)
    )

    let player: AVPlayer = {
        let player = AVPlayer()
        player.isMuted = true
        player.actionAtItemEnd = .none
        player.preventsDisplaySleepDuringVideoPlayback = false
        return player
    }()

    private(set) var source: String?

    /// Bumped on every source change or retry so late results from an older
    /// load are dropped.
    private var generation = 0
    private var retryDelay: TimeInterval = BackgroundVideoPlayer.initialRetryDelay
    private var itemObservers: [NSObjectProtocol] = []
    private var statusObservation: NSKeyValueObservation?
    private let views = NSHashTable<BackgroundVideoView>.weakObjects()

    /// AVAssetResourceLoader only holds its delegate weakly.
    private var playlistLoader: PlaylistLoader?

    /// Told once why `source` failed to load, so a bad link entered in the
    /// Background Video dialog doesn't fail silently. Cleared once it plays.
    private var failureHandler: (source: String, handler: (String) -> Void)?

    private static let initialRetryDelay: TimeInterval = 5
    private static let maxRetryDelay: TimeInterval = 300

    /// A stream can stall without ever failing, for example when the server
    /// keeps redirecting, so an item that isn't ready by then counts as failed.
    private static let loadTimeout: TimeInterval = 30

    func setSource(_ newSource: String?) {
        guard newSource != source else { return }
        source = newSource
        generation += 1
        retryDelay = Self.initialRetryDelay
        load()
    }

    func onNextFailure(of source: String, _ handler: @escaping (String) -> Void) {
        failureHandler = (source, handler)
    }

    private func reportFailure(_ message: String) {
        guard let failureHandler, failureHandler.source == source else { return }
        self.failureHandler = nil
        failureHandler.handler(message)
    }

    func setVolume(_ volume: Double) {
        player.volume = Float(volume)
        player.isMuted = volume <= 0
    }

    /// Applies tint and blur to every window right away, for the sliders in
    /// the Background Video panel. The saved config catches up on reload.
    func preview(opacity: Double, blurRadius: Double) {
        for view in views.allObjects {
            view.tintOpacity = CGFloat(opacity)
            view.blurRadius = CGFloat(blurRadius)
        }
    }

    func register(_ view: BackgroundVideoView) {
        views.add(view)
        updatePlayback()
    }

    func unregister(_ view: BackgroundVideoView) {
        views.remove(view)
        updatePlayback()
    }

    /// Plays only while at least one window showing the video is visible.
    func updatePlayback() {
        let visible = views.allObjects.contains {
            $0.window?.occlusionState.contains(.visible) ?? false
        }
        if visible && player.currentItem != nil {
            player.play()
        } else {
            player.pause()
        }
    }

    private func load() {
        setItem(nil)
        guard let source else { return }

        let generation = self.generation
        DispatchQueue.global(qos: .utility).async {
            let result = Self.resolve(source)
            DispatchQueue.main.async {
                guard generation == self.generation else { return }
                switch result {
                case .success(let stream):
                    self.setItem(self.makeItem(for: stream))
                case .failure(let error):
                    Self.logger.warning("background-video unavailable: \(error.description, privacy: .public)")
                    self.reportFailure(error.description)
                    if error.isRetryable { self.scheduleRetry() }
                }
            }
        }
    }

    private func makeItem(for stream: Stream) -> AVPlayerItem {
        guard let playlist = stream.playlist else {
            let headers = stream.headers
            let options: [String: Any] = headers.isEmpty ? [:] : ["AVURLAssetHTTPHeaderFieldsKey": headers]
            return AVPlayerItem(asset: AVURLAsset(url: stream.url, options: options))
        }

        let loader = PlaylistLoader(playlist: playlist)
        let asset = AVURLAsset(url: PlaylistLoader.url)
        asset.resourceLoader.setDelegate(loader, queue: .main)
        playlistLoader = loader
        return AVPlayerItem(asset: asset)
    }

    private func setItem(_ item: AVPlayerItem?) {
        itemObservers.forEach { NotificationCenter.default.removeObserver($0) }
        itemObservers = []
        statusObservation = nil
        player.replaceCurrentItem(with: item)

        if let item {
            let center = NotificationCenter.default
            itemObservers = [
                center.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                    self?.player.seek(to: .zero)
                },
                center.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                    Self.logger.warning("background-video stream stopped, reloading")
                    self?.scheduleRetry()
                },
            ]
            statusObservation = item.observe(\.status) { [weak self] item, _ in
                let status = item.status
                let message = item.error?.localizedDescription ?? "unknown error"
                DispatchQueue.main.async {
                    guard let self, self.player.currentItem === item else { return }
                    switch status {
                    case .readyToPlay:
                        self.retryDelay = Self.initialRetryDelay
                        self.failureHandler = nil
                    case .failed:
                        Self.logger.warning("background-video failed to play: \(message, privacy: .public)")
                        self.reportFailure(message)
                        self.scheduleRetry()
                    default:
                        break
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.loadTimeout) { [weak self, weak item] in
                guard let self, let item, self.player.currentItem === item, item.status == .unknown else { return }
                Self.logger.warning("background-video timed out loading, reloading")
                self.reportFailure("The video did not start loading within \(Int(Self.loadTimeout)) seconds.")
                self.scheduleRetry()
            }
        }

        updatePlayback()
    }

    /// Stream URLs from yt-dlp expire after a few hours and networks drop,
    /// so failures reload the source with an increasing delay.
    private func scheduleRetry() {
        generation += 1
        setItem(nil)

        let generation = self.generation
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, Self.maxRetryDelay)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, generation == self.generation else { return }
            self.load()
        }
    }
}

// MARK: Source Resolution

extension BackgroundVideoPlayer {
    struct Stream {
        let url: URL
        let headers: [String: String]

        /// An HLS master playlist to play instead of `url`, carrying audio.
        var playlist: Data?
    }

    enum ResolveError: Error, CustomStringConvertible {
        case fileNotFound(String)
        case ytDlpNotFound
        case ytDlpFailed(String)

        var description: String {
            switch self {
            case .fileNotFound(let path):
                return "file not found: \(path)"
            case .ytDlpNotFound:
                return "yt-dlp is required for page URLs (brew install yt-dlp)"
            case .ytDlpFailed(let message):
                return "yt-dlp failed: \(message)"
            }
        }

        var isRetryable: Bool {
            if case .ytDlpFailed = self { return true }
            return false
        }
    }

    /// Files AVFoundation can stream directly, without asking yt-dlp.
    private static let directExtensions: Set<String> = ["mp4", "m4v", "mov", "m3u8"]

    /// H.264 because AVFoundation cannot play YouTube's VP9/WebM streams.
    /// HLS comes first: for long videos the single-file stream is gigabytes,
    /// and YouTube redirects the open-ended range requests AVPlayer makes for
    /// it, so playback never starts. An HLS format also comes with the master
    /// playlist that carries the audio. Live streams only offer muxed HLS,
    /// hence the later fallbacks.
    private static let ytDlpFormat = [
        "bestvideo[vcodec^=avc1][height<=1080][protocol^=m3u8]",
        "bestvideo[vcodec^=avc1][height<=1080]",
        "best[vcodec^=avc1][height<=1080]",
        "best",
    ].joined(separator: "/")

    /// Apps launched from the Dock get a minimal PATH, which hides Homebrew's
    /// yt-dlp and the JavaScript runtime it needs for YouTube.
    private static let extraSearchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "~/.local/bin"]
        .map { ($0 as NSString).expandingTildeInPath }

    static func resolve(_ source: String) -> Result<Stream, ResolveError> {
        let source = source.trimmingCharacters(in: .whitespacesAndNewlines)

        if let url = URL(string: source), let scheme = url.scheme?.lowercased() {
            if scheme == "file" {
                return .success(Stream(url: url, headers: [:]))
            }
            if scheme == "http" || scheme == "https" {
                if directExtensions.contains(url.pathExtension.lowercased()) {
                    return .success(Stream(url: url, headers: [:]))
                }
                return resolveWithYtDlp(source)
            }
        }

        let path = (source as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else {
            return .failure(.fileNotFound(path))
        }
        return .success(Stream(url: URL(fileURLWithPath: path), headers: [:]))
    }

    private static func resolveWithYtDlp(_ page: String) -> Result<Stream, ResolveError> {
        let environment = ProcessInfo.processInfo.environment
        let searchPaths = extraSearchPaths + (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        guard let ytDlp = searchPaths
            .map({ ($0 as NSString).appendingPathComponent("yt-dlp") })
            .first(where: FileManager.default.isExecutableFile(atPath:)) else {
            return .failure(.ytDlpNotFound)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ytDlp)
        process.arguments = ["--dump-json", "--no-playlist", "--no-warnings", "-f", ytDlpFormat, page]
        process.environment = environment.merging(["PATH": searchPaths.joined(separator: ":")]) { $1 }
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            return .failure(.ytDlpFailed(error.localizedDescription))
        }

        // Drain stderr concurrently so a chatty yt-dlp cannot fill the pipe
        // and block while we wait on stdout.
        var errorData = Data()
        let errorRead = DispatchGroup()
        errorRead.enter()
        DispatchQueue.global(qos: .utility).async {
            errorData = stderr.fileHandleForReading.readDataToEndOfFile()
            errorRead.leave()
        }
        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        errorRead.wait()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(bytes: errorData, encoding: .utf8)?
                .split(separator: "\n").last.map(String.init) ?? "exit code \(process.terminationStatus)"
            return .failure(.ytDlpFailed(message))
        }

        guard let info = try? JSONSerialization.jsonObject(with: outputData) as? [String: Any],
              let urlString = info["url"] as? String,
              let url = URL(string: urlString) else {
            return .failure(.ytDlpFailed("no stream URL in yt-dlp output"))
        }

        var stream = Stream(url: url, headers: info["http_headers"] as? [String: String] ?? [:])
        if (info["protocol"] as? String)?.hasPrefix("m3u8") == true,
           let manifest = (info["manifest_url"] as? String).flatMap(URL.init(string:)),
           let multivariant = fetchText(manifest) {
            stream.playlist = PlaylistLoader.narrow(multivariant)
        }
        return .success(stream)
    }

    /// Blocking fetch, only called off the main thread while resolving.
    private static func fetchText(_ url: URL) -> String? {
        var text: String?
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: URLRequest(url: url, timeoutInterval: 15)) { data, response, _ in
            if (response as? HTTPURLResponse)?.statusCode == 200, let data {
                text = String(bytes: data, encoding: .utf8)
            }
            done.signal()
        }.resume()
        done.wait()
        return text
    }
}

// MARK: HLS Master Playlist

/// Serves a rewritten HLS master playlist to AVPlayer on a custom URL scheme.
/// The variant and audio playlists it lists are still loaded from YouTube.
final class PlaylistLoader: NSObject, AVAssetResourceLoaderDelegate {
    static let url = URL(string: "ghostty-background-video://master.m3u8")!

    private let playlist: Data

    init(playlist: Data) {
        self.playlist = playlist
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard loadingRequest.request.url == Self.url else { return false }
        loadingRequest.contentInformationRequest?.contentType = "public.m3u-playlist"
        loadingRequest.contentInformationRequest?.contentLength = Int64(playlist.count)
        loadingRequest.contentInformationRequest?.isByteRangeAccessSupported = false
        loadingRequest.dataRequest?.respond(with: playlist)
        loadingRequest.finishLoading()
        return true
    }

    /// Keeps only the best H.264 variant up to 1080p and its audio group.
    /// YouTube lists a 240p variant first and gives every better variant a
    /// different audio group; AVPlayer starts on the first variant and won't
    /// switch audio groups, so it would otherwise stay at 240p.
    static func narrow(_ multivariant: String) -> Data? {
        struct Variant {
            let height: Int
            let bandwidth: Int
            let index: Int
            let audio: String?
        }

        let lines = multivariant.components(separatedBy: .newlines)
        var best: Variant?
        for (index, line) in lines.enumerated()
        where line.hasPrefix("#EXT-X-STREAM-INF:") && index + 1 < lines.count {
            let mapAttributes = attributes(of: line)
            guard mapAttributes["CODECS"]?.hasPrefix("avc1") == true else { continue }
            let height = mapAttributes["RESOLUTION"]?.split(separator: "x").last.flatMap { Int($0) } ?? 0
            let bandwidth = mapAttributes["BANDWIDTH"].flatMap { Int($0) } ?? 0
            guard height <= 1080 else { continue }
            if let best, (height, bandwidth) <= (best.height, best.bandwidth) { continue }
            best = Variant(height: height, bandwidth: bandwidth, index: index, audio: mapAttributes["AUDIO"])
        }
        guard let best else { return nil }

        let listHeaderPrefixes = ["#EXTM3U", "#EXT-X-VERSION", "#EXT-X-INDEPENDENT-SEGMENTS"]
        var listOutput = lines.filter { line in listHeaderPrefixes.contains { line.hasPrefix($0) } }
        if let audio = best.audio {
            listOutput += lines.filter { $0.hasPrefix("#EXT-X-MEDIA:") && attributes(of: $0)["GROUP-ID"] == audio }
        }
        listOutput += [lines[best.index], lines[best.index + 1]]
        return (listOutput.joined(separator: "\n") + "\n").data(using: .utf8)
    }

    /// Parses the attribute list after the tag, e.g. `A=1,B="x,y"`.
    private static func attributes(of line: String) -> [String: String] {
        guard let colon = line.firstIndex(of: ":") else { return [:] }
        var mapResult: [String: String] = [:]
        var key = ""
        var value = ""
        var inKey = true
        var inQuotes = false
        for char in line[line.index(after: colon)...] {
            switch char {
            case "\"":
                inQuotes.toggle()
            case "=" where inKey:
                inKey = false
            case "," where !inQuotes:
                mapResult[key] = value
                key = ""
                value = ""
                inKey = true
            default:
                if inKey { key.append(char) } else { value.append(char) }
            }
        }
        if !key.isEmpty { mapResult[key] = value }
        return mapResult
    }
}

// MARK: View

/// Shows the shared background video. Sits below the terminal and never
/// takes mouse events.
final class BackgroundVideoView: NSView {
    /// Gaussian blur applied to the video, from `background-video-blur`.
    var blurRadius: CGFloat = 0 {
        didSet {
            guard blurRadius != oldValue else { return }
            updateBlur()
            needsLayout = true
        }
    }

    /// The terminal background color laid over the video. The renderer draws
    /// no background while a video is set, so this is what dims the video.
    var tintColor: NSColor = .black {
        didSet { updateTint() }
    }

    /// From `background-video-opacity`.
    var tintOpacity: CGFloat = 0 {
        didSet { updateTint() }
    }

    private let clipLayer: CALayer = {
        let layer = CALayer()
        layer.masksToBounds = true
        return layer
    }()

    private let playerLayer: AVPlayerLayer = {
        let layer = AVPlayerLayer(player: BackgroundVideoPlayer.shared.player)
        layer.videoGravity = .resizeAspectFill
        return layer
    }()

    private let tintLayer = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerUsesCoreImageFilters = true
        clipLayer.addSublayer(playerLayer)
        clipLayer.addSublayer(tintLayer)
        layer?.addSublayer(clipLayer)
        updateTint()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()

        // A Gaussian blur fades to transparent near the edges, so the video
        // is drawn past our bounds and the blurred fringe is clipped away.
        let margin = blurRadius * 3
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clipLayer.frame = bounds
        playerLayer.frame = clipLayer.bounds.insetBy(dx: -margin, dy: -margin)
        tintLayer.frame = clipLayer.bounds
        CATransaction.commit()
    }

    private func updateTint() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tintLayer.backgroundColor = tintColor.withAlphaComponent(tintOpacity).cgColor
        CATransaction.commit()
    }

    private func updateBlur() {
        guard blurRadius > 0, let blur = CIFilter(name: "CIGaussianBlur") else {
            playerLayer.filters = nil
            return
        }
        blur.setValue(blurRadius, forKey: kCIInputRadiusKey)
        playerLayer.filters = [blur]
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if let window {
            NotificationCenter.default.removeObserver(
                self, name: NSWindow.didChangeOcclusionStateNotification, object: window)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else {
            BackgroundVideoPlayer.shared.unregister(self)
            return
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(occlusionStateDidChange(_:)),
            name: NSWindow.didChangeOcclusionStateNotification,
            object: window)
        BackgroundVideoPlayer.shared.register(self)
    }

    @objc private func occlusionStateDidChange(_ notification: Notification) {
        BackgroundVideoPlayer.shared.updatePlayback()
    }
}
