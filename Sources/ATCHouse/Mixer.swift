import AppKit
import AVFoundation
import WebKit

struct MusicSet: Codable, Hashable, Identifiable {
    var id: String
    var title: String
    var style: String
}

struct LiveFeed: Codable, Hashable, Identifiable {
    var url: String
    var id: String { url }
    var name: String { Self.name(for: url) }

    /// "…hlisten.php?mount=kjfk9_s&icao=kjfk" -> "KJFK9_S"
    static func name(for url: String) -> String {
        let mount = URLComponents(string: url)?.queryItems?.first { $0.name == "mount" }?.value
        return (mount ?? url).uppercased()
    }
}

/// Pulls the 11-char video ID out of any normal YouTube link.
func youtubeID(from link: String) -> String? {
    let s = link.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let c = URLComponents(string: s), let host = c.host?.lowercased() else {
        return s.count == 11 ? s : nil
    }
    var id: String?
    if host.hasSuffix("youtu.be") {
        id = c.path.split(separator: "/").first.map(String.init)
    } else if host.contains("youtube") {
        id = c.queryItems?.first { $0.name == "v" }?.value
        if id == nil {
            let parts = c.path.split(separator: "/").map(String.init)
            if parts.count >= 2, ["embed", "live", "shorts", "v"].contains(parts[0]) { id = parts[1] }
        }
    }
    return id?.count == 11 ? id : nil
}

@MainActor
final class Mixer: NSObject, ObservableObject, WKScriptMessageHandler, WKNavigationDelegate {
    static let styles = ["all", "deep", "tech", "classic", "garage", "coffee"]
    private let defaults = UserDefaults.standard

    // MARK: Music state
    @Published private(set) var bundledSets: [MusicSet] = []
    @Published private(set) var customSets: [MusicSet] = []
    @Published var style = "all"
    @Published private(set) var current: MusicSet?
    @Published private(set) var musicPlaying = false
    @Published private(set) var position: Double = 0     // seconds into current set
    @Published private(set) var duration: Double = 0
    private(set) var iconFrame = 0                        // tick count; not @Published: the panel mustn't redraw 8x a second
    var onTick: (() -> Void)?                             // menu bar icon refresh
    @Published private(set) var allPaused = false
    private var resumeMusic = false
    private var positions: [String: Double]               // set id -> where you left off
    private var ticker: Timer?
    @Published var musicVolume: Double { didSet { applyMusicVolume(); defaults.set(musicVolume, forKey: "musicVolume") } }

    // MARK: ATC state
    enum ATCMode: String { case live, recorded }
    @Published var atcMode: ATCMode { didSet { defaults.set(atcMode.rawValue, forKey: "atcMode") } }
    @Published private(set) var feeds: [LiveFeed] = []
    @Published private(set) var liveFeed: LiveFeed?
    @Published var atcVolume: Double { didSet { applyATCVolume(); defaults.set(atcVolume, forKey: "atcVolume") } }
    @Published private(set) var folder: URL
    @Published private(set) var recordedFile: String?

    private var ytWeb: WKWebView!
    private var ytWindow: NSWindow!
    private var ytReady = false
    private var ytHTML = ""
    private var errorStreak = 0
    @Published private(set) var musicError: String?
    private var pendingPlay: MusicSet?

    private var liveWeb: WKWebView!
    private(set) var liveWindow: NSWindow!
    private var liveHeard = false

    private let recorded = AVPlayer()
    private var endObserver: NSObjectProtocol?

    var allSets: [MusicSet] { bundledSets + customSets }
    var filteredSets: [MusicSet] { style == "all" ? allSets : allSets.filter { $0.style == style } }

    override init() {
        musicVolume = defaults.object(forKey: "musicVolume") as? Double ?? 0.6
        atcVolume = defaults.object(forKey: "atcVolume") as? Double ?? 0.8
        atcMode = ATCMode(rawValue: defaults.string(forKey: "atcMode") ?? "") ?? .live
        positions = defaults.dictionary(forKey: "positions") as? [String: Double] ?? [:]
        folder = URL(fileURLWithPath: defaults.string(forKey: "folder")
                     ?? NSHomeDirectory() + "/Music/ATC")
        super.init()

        if let url = Bundle.main.url(forResource: "sets", withExtension: "json"),
           let data = try? Data(contentsOf: url) {
            bundledSets = (try? JSONDecoder().decode([MusicSet].self, from: data)) ?? []
        }
        customSets = load("customSets") ?? []
        current = allSets.first { $0.id == defaults.string(forKey: "lastSet") }
        feeds = load("feeds") ?? [LiveFeed(url: "https://www.liveatc.net/hlisten.php?mount=kjfk9_s&icao=kjfk")]

        setUpYouTube()
        setUpLive()
        if CommandLine.arguments.contains("--musictest") { musicTest() }
        ticker = Timer.scheduledTimer(withTimeInterval: 0.125, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, (note.object as? AVPlayerItem) === self.recorded.currentItem else { return }
                self.playRandomRecording()
            }
        }
    }

    // MARK: Persistence

    private func load<T: Decodable>(_ key: String) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
    private func save<T: Encodable>(_ value: T, _ key: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }

    // MARK: Music (YouTube IFrame player)

    private func setUpYouTube() {
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.add(self, name: "yt")
        ytWeb = WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 180), configuration: config)
        // The player has to live in a window to keep playing; this one stays hidden.
        ytWindow = NSWindow(contentRect: ytWeb.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        ytWindow.title = "ATC House – Music"
        ytWindow.isReleasedWhenClosed = false
        ytWindow.contentView = ytWeb
        ytHTML = """
        <!doctype html><html><body style="margin:0;background:#000">
        <div id="p"></div>
        <script src="https://www.youtube.com/iframe_api"></script>
        <script>
        var player;
        function post(m){ window.webkit.messageHandlers.yt.postMessage(m); }
        function onYouTubeIframeAPIReady(){
          player = new YT.Player('p', {width:'320', height:'180',
            playerVars:{autoplay:1, playsinline:1, origin:'https://localhost'},
            events:{
              onReady: function(){ post('ready'); },
              onStateChange: function(e){ post('state:' + e.data); },
              onError: function(e){ post('error:' + e.data); }
            }});
        }
        </script></body></html>
        """
        ytWeb.loadHTMLString(ytHTML, baseURL: URL(string: "https://localhost"))
    }

    nonisolated func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            guard let msg = message.body as? String else { return }
            if message.name == "atc" { liveHeard = true; return }
            if msg == "ready" {
                ytReady = true
                musicError = nil
                applyMusicVolume()
                if let s = pendingPlay { pendingPlay = nil; play(s) }
                else if let s = current {                       // reload last set, paused, where you left off
                    js(ytWeb, "player.cueVideoById({videoId:'\(s.id)', startSeconds:\(Int(positions[s.id] ?? 0))})")
                    position = positions[s.id] ?? 0
                }
            } else if msg.hasPrefix("state:") {
                let state = Int(msg.dropFirst(6)) ?? -1
                if state == 1 { musicPlaying = true; allPaused = false; errorStreak = 0; musicError = nil }
                if state == 2 { musicPlaying = false }
                if state == 0, let id = current?.id {           // set finished: start it fresh next time
                    positions[id] = nil
                    next()
                }
            } else if msg.hasPrefix("error:") {
                print("YouTube error \(msg) for \(current?.id ?? "-"), skipping")
                errorStreak += 1
                // A few in a row means we're offline, not a bad video: stop instead of skipping forever.
                if errorStreak < 4 { next() } else { musicPlaying = false; musicError = "Can't reach YouTube. Check your connection and press play." }
            }
        }
    }

    func play(_ set: MusicSet) {
        current = set
        defaults.set(set.id, forKey: "lastSet")
        position = positions[set.id] ?? 0
        duration = 0
        if errorStreak >= 4 { errorStreak = 0; musicError = nil }        // user retrying
        guard ytReady else {
            // Player never loaded (e.g. started offline): load it again; it plays this set when ready.
            if pendingPlay != nil { ytWeb.loadHTMLString(ytHTML, baseURL: URL(string: "https://localhost")) }
            pendingPlay = set
            musicError = "Connecting to YouTube…"
            return
        }
        js(ytWeb, "player.loadVideoById({videoId:'\(set.id)', startSeconds:\(Int(position))}); player.setVolume(\(Int(musicVolume * 100)));")
    }

    var anythingOn: Bool { allPaused || musicPlaying || liveFeed != nil || recordedFile != nil }

    /// One button for both: start both from nothing, otherwise pause all / resume what was playing.
    func togglePauseAll() {
        if !anythingOn { startAll(); return }
        let media = "document.querySelectorAll('audio,video').forEach(function(a){ a.%@ })"
        if allPaused {
            allPaused = false
            if resumeMusic { js(ytWeb, "player.playVideo()") }
            if liveFeed != nil { js(liveWeb, String(format: media, "play().catch(function(){})")) }
            if recordedFile != nil { recorded.play() }
        } else {
            resumeMusic = musicPlaying
            js(ytWeb, "player.pauseVideo()")
            if liveFeed != nil { js(liveWeb, String(format: media, "pause()")) }
            recorded.pause()
            allPaused = true
        }
    }

    /// Last set where you left off (or a shuffle) + last airport (or a random recording).
    private func startAll() {
        if let c = current { play(c) } else { next() }
        if atcMode == .recorded {
            if !recordings.isEmpty { playRandomRecording() }
        } else if let feed = feeds.first(where: { $0.url == defaults.string(forKey: "lastFeed") }) ?? feeds.first {
            playLive(feed)
        }
    }

    func seek(to seconds: Double) {
        position = seconds
        js(ytWeb, "player.seekTo(\(seconds), true)")
    }

    private func tick() {
        iconFrame += 1
        onTick?()
        // Every publish re-renders the panel (even closed), so poll ~1x/s, and while paused only until duration is known.
        guard iconFrame % 8 == 0, musicPlaying || duration == 0 else { return }
        guard ytReady, let id = current?.id else { return }
        Task {
            guard let r = try? await ytWeb.evaluateJavaScript("[player.getCurrentTime(), player.getDuration()]") as? [Double],
                  r.count == 2, current?.id == id else { return }
            if position != r[0] { position = r[0] }
            if duration != r[1] { duration = r[1] }
            if r[0] > 5 { positions[id] = r[0]; defaults.set(positions, forKey: "positions") }
        }
    }

    func toggleMusic() {
        if current == nil { next(); return }
        js(ytWeb, musicPlaying ? "player.pauseVideo()" : "player.playVideo()")
    }

    func next() {
        let pool = filteredSets.filter { $0 != current }
        if let s = pool.randomElement() ?? filteredSets.first { play(s) }
    }

    private func applyMusicVolume() {
        guard ytReady else { return }
        js(ytWeb, "player.setVolume(\(Int(musicVolume * 100)))")
    }

    /// Returns an error message, or nil on success.
    func addSet(link: String, style: String) async -> String? {
        guard let id = youtubeID(from: link) else { return "That doesn't look like a YouTube link." }
        guard !allSets.contains(where: { $0.id == id }) else { return "Already in the list." }
        var title = id
        let oembed = URL(string: "https://www.youtube.com/oembed?format=json&url=https://www.youtube.com/watch?v=\(id)")!
        if let (data, resp) = try? await URLSession.shared.data(from: oembed) {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 || code == 403 { return "That video doesn't allow playing outside YouTube." }
            if code == 404 { return "Couldn't find that video." }
            if let t = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["title"] as? String { title = t }
        }
        let set = MusicSet(id: id, title: title, style: style)
        customSets.append(set)
        save(customSets, "customSets")
        return nil
    }

    func removeCustom(_ set: MusicSet) {
        customSets.removeAll { $0 == set }
        save(customSets, "customSets")
    }

    // MARK: ATC live (LiveATC's own player page, shown in-app)

    private func setUpLive() {
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        // LiveATC's page owns the audio; we press its play once, report when sound starts,
        // and keep its volume in step with our slider.
        let keepVolume = """
        window.__atcVol = window.__atcVol ?? 1;
        setInterval(function(){
          document.querySelectorAll('audio,video').forEach(function(a){
            a.volume = window.__atcVol;
            if (!a.__hooked) {
              a.__hooked = true;
              a.addEventListener('playing', function(){ window.webkit.messageHandlers.atc.postMessage('playing'); });
              if (a.paused) a.play().catch(function(){}); else window.webkit.messageHandlers.atc.postMessage('playing');
            }
          });
        }, 300);
        """
        config.userContentController.add(self, name: "atc")
        config.userContentController.addUserScript(
            WKUserScript(source: keepVolume, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        liveWeb = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 360), configuration: config)
        liveWeb.navigationDelegate = self
        liveWindow = NSWindow(contentRect: liveWeb.frame, styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        liveWindow.title = "LiveATC – press play if needed, then close this window"
        liveWindow.isReleasedWhenClosed = false
        liveWindow.contentView = liveWeb
    }

    func playLive(_ feed: LiveFeed) {
        stopRecorded()
        allPaused = false
        liveFeed = feed
        defaults.set(feed.url, forKey: "lastFeed")
        liveHeard = false
        if let url = URL(string: feed.url) { liveWeb.load(URLRequest(url: url)) }
        // Plays out of sight; only show LiveATC's page if it needs you (human check / play button).
        Task {
            try? await Task.sleep(for: .seconds(8))
            if liveFeed == feed && !liveHeard { showLiveWindow() }
        }
    }

    func showLiveWindow() {
        liveWindow.center()
        NSApp.activate(ignoringOtherApps: true)
        liveWindow.makeKeyAndOrderFront(nil)
    }

    func stopLive() {
        liveFeed = nil
        liveWeb.load(URLRequest(url: URL(string: "about:blank")!))
        liveWindow.orderOut(nil)
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { applyATCVolume() }
    }

    /// Returns an error message, or nil on success.
    func addFeed(link: String) -> String? {
        let s = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let c = URLComponents(string: s), c.host?.hasSuffix("liveatc.net") == true else {
            return "Paste a liveatc.net player link (hlisten.php?mount=…)."
        }
        guard !feeds.contains(where: { $0.url == s }) else { return "Already saved." }
        feeds.append(LiveFeed(url: s))
        save(feeds, "feeds")
        return nil
    }

    func removeFeed(_ feed: LiveFeed) {
        if liveFeed == feed { stopLive() }
        feeds.removeAll { $0 == feed }
        save(feeds, "feeds")
    }

    // MARK: ATC recorded (shuffles a folder of archive files)

    var recordings: [URL] {
        let exts: Set = ["mp3", "m4a", "aac", "wav"]
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { exts.contains($0.pathExtension.lowercased()) }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = folder
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        folder = url
        defaults.set(url.path, forKey: "folder")
    }

    func playRandomRecording() {
        guard let file = recordings.filter({ $0.lastPathComponent != recordedFile }).randomElement()
                ?? recordings.first else { recordedFile = nil; return }
        stopLive()
        allPaused = false
        recordedFile = file.lastPathComponent
        recorded.replaceCurrentItem(with: AVPlayerItem(url: file))
        recorded.volume = Float(atcVolume)
        recorded.play()
    }

    func stopRecorded() {
        recorded.pause()
        recorded.replaceCurrentItem(with: nil)
        recordedFile = nil
    }

    func openFolder() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    private func applyATCVolume() {
        recorded.volume = Float(atcVolume)
        js(liveWeb, "window.__atcVol = \(atcVolume)")
    }

    // MARK: Helpers

    private func js(_ web: WKWebView, _ script: String) {
        // trailing "; 0" so player calls that return objects don't trip WebKit's type check
        web.evaluateJavaScript(script + "; 0") { _, error in
            if let error { print("JS error: \(error.localizedDescription)") }
        }
    }

    /// --musictest: plays a random set, reports the YouTube player state, quits. 1 = playing.
    private func musicTest() {
        next()
        Task {
            try? await Task.sleep(for: .seconds(20))
            let state = try? await ytWeb.evaluateJavaScript("String(player.getPlayerState())")
            print("musictest set=\(current?.id ?? "-") state=\(state ?? "js-failed") playing=\(musicPlaying)")
            exit(0)
        }
    }
}

enum MenuIcon {
    static let plane: NSImage = {
        let img = NSImage(systemSymbolName: "airplane.circle", accessibilityDescription: "ATC House")!
        img.isTemplate = true
        return img
    }()

    /// Four bars that dance while music plays.
    /// shortcut: animated, not driven by the actual audio (YouTube's player doesn't expose levels).
    static func bars(frame: Int) -> NSImage {
        let f = Double(frame)
        let heights = (0..<4).map { i -> CGFloat in
            let d = Double(i)
            let level = (0.5 + 0.5 * sin(f * 0.9 + d * 1.7)) * (0.6 + 0.4 * sin(f * 0.37 + d * 2.9))
            return 3 + 11 * CGFloat(level)
        }
        let img = NSImage(size: NSSize(width: 18, height: 16), flipped: false) { _ in
            for (i, h) in heights.enumerated() {
                NSBezierPath(roundedRect: NSRect(x: 1.5 + CGFloat(i) * 4.25, y: (16 - h) / 2, width: 2.5, height: h),
                             xRadius: 1.25, yRadius: 1.25).fill()
            }
            return true
        }
        img.isTemplate = true
        return img
    }
}
