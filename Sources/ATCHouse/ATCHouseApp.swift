import ServiceManagement
import SwiftUI

@main
struct ATCHouseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        if CommandLine.arguments.contains("--selftest") { selfTest(); exit(0) }
    }

    var body: some Scene { Settings { EmptyView() } }
}

/// Plain AppKit status item + popover: SwiftUI's MenuBarExtra closed the panel every time the icon animated.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mixer: Mixer!
    private lazy var item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)  // lazy: --snapshot mustn't create one
    private let popover = NSPopover()
    private var showingBars = false
    // Icon drawn in a subview: changing the button's own image re-lays out the item and closes the panel.
    private let iconView = PassThroughImageView()

    func applicationDidFinishLaunching(_ note: Notification) {
        mixer = Mixer()
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot") {
            guard i + 1 < CommandLine.arguments.count else { print("usage: --snapshot <dir>"); exit(1) }
            snapshot(mixer, to: CommandLine.arguments[i + 1]); exit(0)
        }
        let host = NSHostingController(rootView: PanelView().environmentObject(mixer))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient
        if let button = item.button {
            iconView.frame = button.bounds
            iconView.autoresizingMask = [.width, .height]
            iconView.imageScaling = .scaleNone
            iconView.image = MenuIcon.plane
            button.addSubview(iconView)
        }
        item.button?.setAccessibilityTitle("ATC House")
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        mixer.onTick = { [weak self] in self?.refreshIcon() }
        // .transient misses clicks in other apps (we're a menu bar-only app), so close on those ourselves.
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.popover.performClose(nil) }
        }
    }

    private func refreshIcon() {
        if mixer.musicPlaying {
            iconView.image = MenuIcon.bars(frame: mixer.iconFrame)
            showingBars = true
        } else if showingBars {
            iconView.image = MenuIcon.plane
            showingBars = false
        }
    }

    @objc private func togglePanel() {
        guard let button = item.button else { return }
        if popover.isShown { popover.performClose(nil); return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
}

/// Lets clicks through to the status item button underneath.
final class PassThroughImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private enum Brand {
    // Lighter orange on dark, deeper on light so it holds 3:1 against the popover in both.
    static let accent = Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(srgbRed: 1.00, green: 0.62, blue: 0.30, alpha: 1)    // #FF9E4D
        : NSColor(srgbRed: 0.85, green: 0.40, blue: 0.06, alpha: 1) }) // #D9660F
    static let navy = Color(red: 0.102, green: 0.110, blue: 0.239)     // #1A1C3D
    static let plum = Color(red: 0.302, green: 0.141, blue: 0.420)     // #4D246B
}

private struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

private extension View {
    func module() -> some View {
        padding(12)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 0.5))
    }
}

struct PanelView: View {
    @EnvironmentObject var m: Mixer
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var feedLink = ""
    @State private var feedError: String?
    @State private var setLink = ""
    @State private var setStyle = "deep"
    @State private var setError: String?
    @State private var showAddSet = false
    @State private var loginTick = false
    @State private var scrubbing = false
    @State private var scrubValue = 0.0
    @State private var hoveredFeed: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            atcModule
            houseModule
            footer
        }
        .padding(12)
        .frame(width: 340)
    }

    // MARK: Header

    private var status: String {
        if !m.anythingOn { return "Off. Press play to start both." }
        if m.allPaused { return "Paused" }
        let atc = m.liveFeed?.name ?? (m.recordedFile != nil ? "Recorded ATC" : nil)
        let music = m.musicPlaying ? "\(m.current?.style ?? m.style) house" : nil
        let parts = [atc, music].compactMap { $0 }
        return parts.isEmpty ? "Playing" : parts.joined(separator: " with ")
    }

    private var header: some View {
        let showPlay = m.allPaused || !m.anythingOn
        let hint = showPlay ? "Play ATC + music" : "Pause both"
        return HStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)   // brand anchor: brings the palette in even when idle
                .resizable().frame(width: 26, height: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("ATC House").font(.system(size: 15, weight: .semibold))
                Text(status).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button { m.togglePauseAll() } label: {
                Circle()
                    .fill(LinearGradient(colors: [Brand.navy, Brand.plum], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(Circle().strokeBorder(.white.opacity(0.22), lineWidth: 0.5))
                    .padding(showPlay ? 0 : 2.5)
                    .background(Circle().strokeBorder(Brand.accent, lineWidth: 1.5).opacity(showPlay ? 0 : 1))
                    .overlay(
                        Image(systemName: showPlay ? "play.fill" : "pause.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .offset(x: showPlay ? 1 : 0)   // optically centre the play triangle
                            .contentTransition(.symbolEffect(.replace)))
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(PressScale())
            .help(hint)
            .accessibilityLabel(hint)
        }
        .padding(.horizontal, 4)
    }

    // MARK: Air traffic

    private var atcModule: some View {
        let recs = m.recordings   // disk read: once per render
        let live = m.atcMode == .live
        return VStack(alignment: .leading, spacing: 10) {
            moduleHeader(symbol: "antenna.radiowaves.left.and.right", title: "Air traffic",
                         subtitle: live ? m.liveFeed?.name ?? "Off" : m.recordedFile ?? "\(recs.count) recordings",
                         active: (m.liveFeed != nil || m.recordedFile != nil) && !m.allPaused) {
                Picker("ATC source", selection: $m.atcMode) {
                    Text("Live").tag(Mixer.ATCMode.live)
                    Text("Recorded").tag(Mixer.ATCMode.recorded)
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.small).frame(width: 136)
            }
            if live { liveControls } else { recordedControls(recs) }
            volumeRow(icon: "headphones", value: $m.atcVolume, label: "ATC volume")
        }
        .module()
    }

    @ViewBuilder private var feedList: some View {
        let rows = VStack(spacing: 2) { ForEach(m.feeds) { feedRow($0) } }
        // Negative inset: row contents line up with the module edge, the hover fill bleeds past it.
        if m.feeds.count > 6 { ScrollView { rows }.frame(maxHeight: 180).padding(.horizontal, -6) } else { rows.padding(.horizontal, -6) }
    }

    private func feedRow(_ feed: LiveFeed) -> some View {
        let active = m.liveFeed == feed
        let hovered = hoveredFeed == feed.id
        return HStack(spacing: 10) {
            Button { active ? m.stopLive() : m.playLive(feed) } label: {
                circle(active ? "stop.fill" : "play.fill", size: 20, active: active).frame(width: 26)
            }
            .buttonStyle(.plain)
            .help(active ? "Stop \(feed.name)" : "Play \(feed.name)")
            .accessibilityLabel(active ? "Stop \(feed.name)" : "Play \(feed.name)")
            Text(feed.name)
                .font(.system(size: 12, weight: active ? .medium : .regular, design: .monospaced))
                .lineLimit(1)
            if active {
                Image(systemName: "waveform")
                    .font(.system(size: 10))
                    .foregroundStyle(Brand.accent)
                    .symbolEffect(.variableColor.iterative, isActive: !m.allPaused && !reduceMotion)
                    .accessibilityHidden(true)
            }
            Spacer()
            if active {
                Button { m.showLiveWindow() } label: { Label("Player", systemImage: "macwindow") }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                    .help("Show the LiveATC player")
            }
            Button { m.removeFeed(feed) } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(hovered ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
            .help("Remove \(feed.name)")
            .accessibilityLabel("Remove \(feed.name)")
        }
        .padding(.horizontal, 6)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.primary.opacity(hovered ? 0.06 : 0)))
        .onHover { hoveredFeed = $0 ? feed.id : (hoveredFeed == feed.id ? nil : hoveredFeed) }
    }

    private var liveControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            if m.feeds.isEmpty {
                Text("No feeds yet. Paste a player link from liveatc.net below.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                feedList
            }
            linkField(icon: "link", placeholder: "Paste LiveATC player link", text: $feedLink, add: addFeed, help: "Add feed")
            if let feedError { errorText(feedError) }
            Text("Plays in the background. If LiveATC needs you (human check), its page pops up.")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func addFeed() {
        feedError = m.addFeed(link: feedLink)
        if feedError == nil { feedLink = "" }
    }

    private func recordedControls(_ recs: [URL]) -> some View {
        let path = m.folder.path
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button { m.recordedFile == nil ? m.playRandomRecording() : m.stopRecorded() } label: {
                    circle(m.recordedFile == nil ? "play.fill" : "stop.fill", size: 20, active: m.recordedFile != nil)
                        .frame(width: 26)
                }
                .buttonStyle(.plain)
                .disabled(recs.isEmpty)
                .help(m.recordedFile == nil ? "Play a random recording" : "Stop recording")
                .accessibilityLabel(m.recordedFile == nil ? "Play a random recording" : "Stop recording")
                Button { m.playRandomRecording() } label: {
                    Image(systemName: "forward.fill").font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .disabled(recs.isEmpty)
                .help("Skip to another recording")
                .accessibilityLabel("Skip to another recording")
                Text(m.recordedFile ?? "\(recs.count) recordings")
                    .font(.system(size: 12, weight: m.recordedFile != nil ? .medium : .regular, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
            }
            HStack(spacing: 6) {
                Image(systemName: "folder").font(.system(size: 11)).foregroundStyle(.tertiary)
                Text(path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.head)
                    .help(path)
                Spacer()
                Group {
                    Button("Open") { m.openFolder() }
                    Button("Change…") { m.chooseFolder() }
                }
                .buttonStyle(.borderless).controlSize(.small).font(.system(size: 11))
            }
            if recs.isEmpty {
                Text("Download a few files from LiveATC's archive into this folder.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: House

    private var houseModule: some View {
        VStack(alignment: .leading, spacing: 10) {
            moduleHeader(symbol: "music.note", title: "House", subtitle: "\(m.filteredSets.count) sets",
                         active: m.musicPlaying) {
                Menu {
                    if m.filteredSets.isEmpty { Text("No sets in this style") }
                    ForEach(m.filteredSets) { s in Button(s.title) { m.play(s) } }
                    if !m.customSets.isEmpty {
                        Divider()
                        Menu("Remove one of mine") {
                            ForEach(m.customSets) { s in Button(s.title) { m.removeCustom(s) } }
                        }
                    }
                } label: {
                    Label("Pick a set", systemImage: "music.note.list").labelStyle(.iconOnly)
                }
                .accessibilityLabel("Pick a set")
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Pick a set")
            }

            Picker("Style", selection: $m.style) {
                ForEach(Mixer.styles, id: \.self) { Text($0.capitalized).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().controlSize(.small)

            if let e = m.musicError {
                if e.hasPrefix("Connecting") {
                    Text(e).font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    errorText(e)
                }
            }

            HStack(alignment: .top, spacing: 10) {
                Text(m.current?.title ?? "Nothing playing")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(m.current == nil ? .secondary : .primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button { m.toggleMusic() } label: {
                    circle(m.musicPlaying ? "pause.fill" : "play.fill", size: 28, active: false)
                }
                .buttonStyle(PressScale())
                .help(m.musicPlaying ? "Pause music" : "Play music")
                .accessibilityLabel(m.musicPlaying ? "Pause music" : "Play music")
                Button { m.next() } label: { circle("forward.fill", size: 28, active: false) }
                    .buttonStyle(PressScale())
                    .help("Shuffle to another set")
                    .accessibilityLabel("Shuffle to another set")
            }

            if m.duration > 0 {
                VStack(spacing: 2) {
                    // Local scrubbing state so the 1 Hz position poll doesn't yank the knob mid-drag.
                    Slider(value: Binding(get: { scrubbing ? scrubValue : m.position },
                                          set: { scrubValue = $0 }),
                           in: 0...m.duration) { editing in
                        if editing { scrubValue = m.position; scrubbing = true }
                        else { m.seek(to: scrubValue); scrubbing = false }
                    }
                    .controlSize(.mini).tint(Brand.accent)
                    .accessibilityLabel("Position")
                    .accessibilityValue("\(clock(scrubbing ? scrubValue : m.position)) of \(clock(m.duration))")
                    HStack {
                        Text(clock(scrubbing ? scrubValue : m.position))
                        Spacer()
                        Text(clock(m.duration))
                    }
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                }
            }

            volumeRow(icon: "speaker.wave.2.fill", value: $m.musicVolume, label: "Music volume")

            Divider().opacity(0.5)
            addSetSection
        }
        .module()
    }

    private var addSetSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            // No withAnimation: the popover animates its own resize.
            Button { showAddSet.toggle() } label: {
                HStack {
                    Image(systemName: "plus").font(.system(size: 11))
                    Text("Add a set").font(.system(size: 12))
                    Spacer()
                    Image(systemName: "chevron.down").font(.system(size: 10)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(showAddSet ? 180 : 0))
                        .animation(.snappy(duration: 0.2), value: showAddSet)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add a set")
            .accessibilityValue(showAddSet ? "expanded" : "collapsed")

            if showAddSet {
                linkField(icon: "play.rectangle", placeholder: "YouTube link", text: $setLink, add: addSet, help: "Add set")
                HStack {
                    Text("Style").font(.system(size: 11)).foregroundStyle(.secondary)
                    Picker("Style", selection: $setStyle) {
                        ForEach(Mixer.styles.dropFirst(), id: \.self) { Text($0.capitalized).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.menu).controlSize(.small).fixedSize()
                    Spacer()
                    Button("Add", action: addSet).controlSize(.small).disabled(setLink.isEmpty)
                }
                if let setError { errorText(setError) }
            }
        }
    }

    private func addSet() {
        Task {
            setError = await m.addSet(link: setLink, style: setStyle)
            if setError == nil { setLink = "" }
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Toggle("Open at login", isOn: Binding(
                    get: { SMAppService.mainApp.status == .enabled },
                    set: { on in
                        try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                        loginTick.toggle()                      // re-read status
                    }))
                .toggleStyle(.switch).controlSize(.mini).font(.system(size: 11))
                .id(loginTick)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
                    .buttonStyle(.borderless).font(.system(size: 11)).foregroundStyle(.secondary)
                    .help("Quit ATC House (⌘Q)")
            }
            Text("ATC House \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") · by Mitchel McKee")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }

    // MARK: Pieces

    private func circle(_ symbol: String, size: CGFloat, active: Bool) -> some View {
        Circle()
            .fill(active ? Brand.accent : Color.primary.opacity(0.10))
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.4, weight: .bold))
                    .foregroundStyle(active ? Brand.navy : .primary)
                    .contentTransition(.symbolEffect(.replace)))
            .frame(width: size, height: size)
    }

    private func moduleHeader(symbol: String, title: String, subtitle: String, active: Bool,
                              @ViewBuilder trailing: () -> some View) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(active ? Brand.accent : Color.secondary.opacity(0.18))
                .overlay(Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(active ? Brand.navy : .secondary))
                .frame(width: 26, height: 26)
                .accessibilityHidden(true)
                .animation(.easeOut(duration: 0.2), value: active)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            trailing()
        }
    }

    private func linkField(icon: String, placeholder: String, text: Binding<String>,
                           add: @escaping () -> Void, help: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(.tertiary)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain).font(.system(size: 12))
                .onSubmit(add)
            Button(action: add) { Image(systemName: "plus.circle.fill").font(.system(size: 15)) }
                .foregroundStyle(text.wrappedValue.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Brand.accent))
                .buttonStyle(.plain)
                .disabled(text.wrappedValue.isEmpty)
                .help(help)
                .accessibilityLabel(help)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.background.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
    }

    private func errorText(_ s: String) -> some View {
        Label(s, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 11)).foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func volumeRow(icon: String, value: Binding<Double>, label: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 26)
            Slider(value: value, in: 0...1).controlSize(.small).tint(Brand.accent).accessibilityLabel(label)
        }
    }
}

/// 3725 -> "1:02:05", 125 -> "2:05"
func clock(_ seconds: Double) -> String {
    let t = Int(max(0, seconds))
    let (h, m, s) = (t / 3600, t / 60 % 60, t % 60)
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}

// Run with --snapshot <dir>: renders the panel offscreen to <dir>/panel-dark.png and panel-light.png.
@MainActor private func snapshot(_ mixer: Mixer, to dir: String) {
    let host = NSHostingView(rootView: PanelView().environmentObject(mixer))
    let backdrop = NSVisualEffectView()          // stands in for the popover's material
    backdrop.material = .popover
    backdrop.state = .active
    backdrop.addSubview(host)
    let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 340, height: 600),
                          styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = backdrop
    window.setFrameOrigin(NSPoint(x: -5000, y: -5000))   // never on a visible screen
    window.orderBack(nil)
    RunLoop.main.run(until: Date().addingTimeInterval(3))
    for (name, look) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
        window.appearance = NSAppearance(named: look)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let size = host.fittingSize
        window.setContentSize(size)
        host.frame = NSRect(origin: .zero, size: size)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        guard let rep = backdrop.bitmapImageRepForCachingDisplay(in: backdrop.bounds) else { continue }
        backdrop.cacheDisplay(in: backdrop.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: dir).appendingPathComponent("panel-\(name).png"))
    }
    window.orderOut(nil)
}

// Run with --selftest: checks the link parsers.
private func selfTest() {
    precondition(youtubeID(from: "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=10") == "dQw4w9WgXcQ")
    precondition(youtubeID(from: "https://youtu.be/dQw4w9WgXcQ?si=abc") == "dQw4w9WgXcQ")
    precondition(youtubeID(from: "https://www.youtube.com/live/dQw4w9WgXcQ") == "dQw4w9WgXcQ")
    precondition(youtubeID(from: "https://example.com/watch?v=dQw4w9WgXcQ") == nil)
    precondition(youtubeID(from: "not a link") == nil)
    precondition(LiveFeed.name(for: "https://www.liveatc.net/hlisten.php?mount=kjfk9_s&icao=kjfk") == "KJFK9_S")
    precondition(clock(3725) == "1:02:05" && clock(125) == "2:05")
    print("selftest ok")
}
