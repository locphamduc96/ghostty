import AppKit
import OSLog
import WebKit

/// Signs in to YouTube in a window of its own, so `yt-dlp` can pass YouTube's
/// "confirm you're not a bot" check without reading cookies from a browser.
///
/// The sign-in lives in this app's own web data store, apart from every
/// browser and from the Keychain, and its cookies are copied to a file that
/// `yt-dlp` reads. The password is only ever typed into Google's page.
final class BackgroundVideoLogin: NSObject, ObservableObject {
    static let shared = BackgroundVideoLogin()

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier!,
        category: String(describing: BackgroundVideoLogin.self)
    )

    private static let signInURL = URL(
        string: "https://accounts.google.com/ServiceLogin?service=youtube&continue=https%3A%2F%2Fwww.youtube.com%2F")!

    /// In Application Support rather than the config directory, which is
    /// often kept in a dotfiles repository.
    static var cookiesURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.mitchellh.ghostty")
            .appendingPathComponent("youtube-cookies.txt")
    }

    static var hasCookies: Bool {
        FileManager.default.fileExists(atPath: cookiesURL.path)
    }

    @Published private(set) var isSignedIn = BackgroundVideoLogin.hasCookies

    private var window: NSWindow?
    private var webView: WKWebView?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 680), configuration: .init())
        webView.navigationDelegate = self
        webView.uiDelegate = self

        let window = NSWindow(
            contentRect: webView.frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "Sign in to YouTube"
        window.contentView = webView
        window.isReleasedWhenClosed = false
        window.delegate = self

        // The Background Video panel it is opened from floats, and would
        // otherwise cover this window.
        window.level = .floating
        window.center()

        self.window = window
        self.webView = webView
        webView.load(URLRequest(url: Self.signInURL))
        window.makeKeyAndOrderFront(nil)
    }

    func signOut() {
        try? FileManager.default.removeItem(at: Self.cookiesURL)
        WKWebsiteDataStore.default().removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: .distantPast
        ) {}
        isSignedIn = false
        BackgroundVideoPlayer.shared.reloadWebLink()
    }

    /// Called after every page load. Once YouTube has set its sign-in cookies,
    /// they are saved for `yt-dlp` and the window closes.
    private func saveCookiesIfSignedIn() {
        webView?.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self else { return }
            let relevant = cookies.filter { Self.isGoogleDomain($0.domain) }

            // The cookies YouTube sets once signed in, which yt-dlp also looks for.
            let signedIn = relevant.contains {
                $0.domain.hasSuffix("youtube.com") && ["SAPISID", "__Secure-3PAPISID"].contains($0.name)
            }
            guard signedIn else { return }

            do {
                try Self.write(relevant)
            } catch {
                Self.logger.warning("could not save YouTube cookies: \(error.localizedDescription, privacy: .public)")
                return
            }
            self.isSignedIn = true
            self.window?.close()
            BackgroundVideoPlayer.shared.reloadWebLink()
        }
    }

    private static func isGoogleDomain(_ domain: String) -> Bool {
        domain.hasSuffix("youtube.com") || domain.hasSuffix("google.com")
    }

    /// Netscape cookie file, the format `yt-dlp --cookies` reads. A `0`
    /// expiry marks a session cookie.
    private static func write(_ cookies: [HTTPCookie]) throws {
        var lines = ["# Netscape HTTP Cookie File"]
        for cookie in cookies {
            let expires = cookie.expiresDate.map { Int($0.timeIntervalSince1970) } ?? 0
            lines.append([
                (cookie.isHTTPOnly ? "#HttpOnly_" : "") + cookie.domain,
                cookie.domain.hasPrefix(".") ? "TRUE" : "FALSE",
                cookie.path,
                cookie.isSecure ? "TRUE" : "FALSE",
                String(expires),
                cookie.name,
                cookie.value,
            ].joined(separator: "\t"))
        }

        try FileManager.default.createDirectory(
            at: cookiesURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)

        // Owner-only, since these cookies are a sign-in.
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        guard FileManager.default.createFile(
            atPath: cookiesURL.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cookiesURL.path)
    }
}

extension BackgroundVideoLogin: WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        saveCookiesIfSignedIn()
    }

    /// Links that ask for a new window, such as Google's help pages, open in
    /// this one so there is only ever one web view to sign in with.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        webView.load(navigationAction.request)
        return nil
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        webView = nil
    }
}
