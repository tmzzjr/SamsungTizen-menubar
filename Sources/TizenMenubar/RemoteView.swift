import SwiftUI
import AppKit

private let accent = BrandTheme.samsungBlue
private let mutedInk = Color.white.opacity(0.49)

private enum RemoteTab: String, CaseIterable, Identifiable {
    case home = "Your TV", remote = "Remote", apps = "Apps", media = "Cast", usage = "Activity"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .home: return "tv"
        case .remote: return "dpad"
        case .apps: return "square.grid.2x2"
        case .media: return "airplay.video"
        case .usage: return "chart.bar.xaxis"
        }
    }
}

private struct PanelButton: ButtonStyle {
    var selected = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(selected ? accent : Color.white.opacity(0.79))
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? accent.opacity(0.19) : Color.white.opacity(configuration.isPressed ? 0.13 : 0.065)))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

private struct PanelCard<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        content.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.068)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.085), lineWidth: 0.7))
    }
}

struct AppMark: View {
    let app: TVApp
    var size: CGFloat = 36
    var body: some View {
        Group {
            if let url = AppIcons.url(for: app), let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08))
                    Text(String(app.title.prefix(1)).uppercased()).font(.system(size: size * 0.42, weight: .semibold)).foregroundStyle(mutedInk)
                }
            }
        }.frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: size * 0.23))
            .accessibilityHidden(true)
    }
}

private struct BrandImage: View {
    let name: String
    var width: CGFloat = 28
    var height: CGFloat = 28
    var body: some View {
        Group {
            if let url = AppResources.bundle.url(forResource: name, withExtension: "png", subdirectory: "AppAssets"), let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
            }
        }.frame(width: width, height: height).accessibilityHidden(true)
    }
}

struct RemoteView: View {
    @ObservedObject var store: RemoteStore
    @State private var tab: RemoteTab = .home
    @State private var settings = false
    @State private var search = ""
    @State private var text = ""
    @State private var draftHost = ""
    @State private var draftName = ""
    @State private var draftMAC = ""
    @State private var usageDays = 1
    @State private var showEvents = false
    @State private var swipeTranslation = CGSize.zero
    private var currentApp: TVApp? { store.currentAppID.flatMap { id in store.apps.first { $0.id == id } } }
    private var theme: BrandTheme {
        BrandTheme.forApp(store.displayForegroundID, title: store.currentInput?.label ?? store.currentApp, icon: currentApp.flatMap(AppIcons.url))
    }
    private var accent: Color { theme.color }
    private var activeTitle: String { isPlayStation ? "PlayStation 5" : store.currentApp }
    var body: some View {
        VStack(spacing: 0) {
            header.padding(.top, 16).padding(.bottom, 16)
            tabs.padding(.bottom, 14)
            contentScroll
            footer.padding(.top, 10).padding(.bottom, 12)
        }.padding(.horizontal, 13).frame(width: 360)
            .background(LinearGradient(colors: [Color(red: 0.065, green: 0.070, blue: 0.080), Color(white: 0.042)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .foregroundStyle(Color.white.opacity(0.86)).preferredColorScheme(.dark)
            .font(.system(size: 12))
            .tint(accent)
            .animation(.easeOut(duration: 0.22), value: store.displayForegroundID)
            .onChange(of: tab) { _, value in store.preferredPanelHeight = preferredHeight(value) }
            .onChange(of: settings) { _, value in store.preferredPanelHeight = value ? 650 : preferredHeight(tab) }
            .onAppear { if store.host.isEmpty { showConnectionSettings() } }
    }
    private func preferredHeight(_ tab: RemoteTab) -> CGFloat { tab == .home || tab == .remote ? 740 : tab == .media ? 590 : tab == .usage ? 580 : 660 }
    private var contentScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if settings { settingsPanel }
                else {
                    if tab != .home { sectionTitle(tab.rawValue) }
                    if !store.connected { connectionPanel }
                    tabContent
                }
                feedback
            }.padding(.bottom, 12)
        }.scrollIndicators(.hidden)
    }
    @ViewBuilder private var tabContent: some View {
        switch tab {
        case .home: homePanel
        case .remote: remotePanel
        case .apps: appsPanel
        case .media: mediaPanel
        case .usage: usagePanel
        }
    }
    @ViewBuilder private var feedback: some View {
        if let error = store.error {
            PanelCard {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                    Text(error).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button { store.error = nil } label: { Image(systemName: "xmark").font(.system(size: 10)) }.buttonStyle(.plain).help("Dismiss message")
                }
            }
        } else if let notice = store.notice {
            Text(notice).font(.system(size: 11)).foregroundStyle(mutedInk).fixedSize(horizontal: false, vertical: true)
        }
    }
    private var header: some View {
        HStack(spacing: 9) {
            VStack(alignment: .leading, spacing: 5) {
                Text(store.name).font(.system(size: 17, weight: .semibold)).tracking(-0.3).lineLimit(1)
                HStack(spacing: 6) {
                    BrandImage(name: "samsung", width: 54, height: 8).opacity(0.55)
                    Text(store.system.isEmpty ? "Tizen" : store.system).font(.system(size: 10, weight: .medium)).foregroundStyle(mutedInk)
                }
            }
            Spacer()
            Menu {
                Button("Refresh TV data") { Task { await store.refreshInfo(); await store.refresh(); await store.refreshState() } }
                Button(store.connected ? "Disconnect" : "Connect") {
                    if store.connected { store.disconnect() }
                    else if store.host.isEmpty { showConnectionSettings() }
                    else { store.connect() }
                }
                Divider()
                Button("Quit SamsungTizen-menubar") { NSApplication.shared.terminate(nil) }
            } label: { Image(systemName: "ellipsis").frame(width: 24, height: 30).foregroundStyle(mutedInk) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            Menu {
                if store.connected { Button("Turn TV off") { store.power() } }
                else { Button("Wake TV over Wi-Fi") { store.power() }.disabled(store.mac.isEmpty) }
            } label: {
                Image(systemName: "power").font(.system(size: 17)).foregroundStyle(store.connected ? .white : mutedInk)
                    .frame(width: 34, height: 34).background(Circle().fill(Color.white.opacity(0.06)))
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("TV power")
        }
    }
    private var tabs: some View {
        HStack(spacing: 4) {
            ForEach(RemoteTab.allCases) { item in
                Button { tab = item; settings = false } label: {
                    Image(systemName: item.symbol).font(.system(size: 16, weight: .medium))
                        .foregroundStyle(tab == item && !settings ? accent : mutedInk)
                        .frame(maxWidth: .infinity).frame(height: 35)
                        .background(RoundedRectangle(cornerRadius: 9).fill(tab == item && !settings ? accent.opacity(0.2) : .clear))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).help(item.rawValue).accessibilityLabel(item.rawValue)
            }
        }.padding(4).background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.066)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.08), lineWidth: 0.7))
    }
    private func sectionTitle(_ title: String) -> some View {
        HStack {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.white.opacity(0.72))
            Spacer()
            if store.connecting { ProgressView().controlSize(.mini) }
        }.padding(.horizontal, 1)
    }
    private var homePanel: some View {
        VStack(spacing: 12) {
            nowPlayingCard
            audioCard
            if !store.pinnedApps.isEmpty {
                PanelCard {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label("Favorites", systemImage: "star").font(.system(size: 12, weight: .semibold))
                            Spacer()
                            Button { tab = .apps } label: { Text("See all").font(.system(size: 10)).foregroundStyle(mutedInk) }.buttonStyle(.plain)
                        }
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 13) {
                            ForEach(store.pinnedApps) { app in
                                Button { store.launch(app) } label: {
                                    VStack(spacing: 8) { AppMark(app: app, size: 34); Text(app.title).font(.system(size: 9, weight: .medium)).foregroundStyle(Color.white.opacity(0.7)).lineLimit(1) }
                                        .frame(maxWidth: .infinity).padding(.vertical, 4).contentShape(Rectangle())
                                }.buttonStyle(.plain).disabled(!store.connected).help("Open \(app.title) on TV")
                            }
                        }
                    }
                }
            }
            PanelCard {
                VStack(spacing: 7) {
                    HStack { Label("Inputs", systemImage: "cable.connector").font(.system(size: 12, weight: .semibold)); Spacer() }
                    ForEach(store.inputs) { input in inputRow(input) }
                }
            }
            if !store.mostUsedApps.isEmpty {
                HStack(spacing: 8) {
                    Text("Most used").font(.system(size: 10)).foregroundStyle(mutedInk)
                    Spacer()
                    ForEach(Array(store.mostUsedApps.prefix(4))) { app in
                        Button { store.launch(app) } label: { AppMark(app: app, size: 25) }.buttonStyle(.plain).help("Open \(app.title)").disabled(!store.connected)
                    }
                    Button { tab = .usage } label: { Image(systemName: "chevron.right").foregroundStyle(mutedInk) }.buttonStyle(.plain).help("View activity")
                }.padding(.horizontal, 4)
            }
        }
    }
    private var isPlayStation: Bool {
        store.currentInput?.label.localizedCaseInsensitiveContains("PS5") == true || store.currentInput?.label.localizedCaseInsensitiveContains("PlayStation") == true
    }
    private var nowPlayingCaption: String {
        guard store.connected else { return "Your TV, on your Mac" }
        if store.homeRequested { return "Home opened from your Mac" }
        return store.currentAppID != nil || store.currentInput != nil ? "Opened from your Mac" : "Connected"
    }
    private var nowPlayingCard: some View {
        VStack(spacing: 0) {
            ZStack {
                Ellipse().fill(accent.opacity(store.connected ? 0.28 : 0.08)).frame(width: 230, height: 110).blur(radius: 38).offset(y: 9)
                BrandImage(name: "tv-hero", width: 312, height: 178)
                VStack(spacing: 11) {
                    if isPlayStation { BrandImage(name: "playstation", width: 45, height: 45) }
                    else if let app = currentApp { AppMark(app: app, size: 43) }
                    else if store.currentInput?.label.localizedCaseInsensitiveContains("Chromecast") == true { BrandImage(name: "googlecast", width: 37, height: 37) }
                    else { BrandImage(name: "samsung", width: 112, height: 18) }
                    if store.connected { Text(activeTitle).font(.system(size: 15, weight: .semibold)).tracking(-0.3).lineLimit(1) }
                }.offset(y: -6).shadow(color: accent.opacity(0.5), radius: 16)
            }.frame(height: 174)
            HStack(spacing: 5) {
                Circle().fill(store.connected ? accent : mutedInk).frame(width: 5, height: 5)
                Text(nowPlayingCaption).font(.system(size: 10, weight: .medium)).foregroundStyle(mutedInk)
                Spacer()
                if let input = store.currentInput, input.label != defaultLabel(input) { Text(defaultLabel(input)).font(.system(size: 10, weight: .semibold)).foregroundStyle(accent) }
            }.padding(.horizontal, 10).padding(.top, 7)
            Text(theme.tagline).font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.65)).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 7)
        }.padding(.top, 2)
    }
    private var audioCard: some View {
        PanelCard {
            VStack(spacing: 12) {
                HStack {
                    Image(systemName: "speaker.wave.2.fill").foregroundStyle(mutedInk)
                    Text("TV audio").fontWeight(.semibold)
                    Spacer()
                    if store.hasVolume { Text("\(Int(store.volume))").font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit().contentTransition(.numericText()) }
                }
                HStack(spacing: 9) {
                    Button { store.toggleMute() } label: { Image(systemName: store.muted ? "speaker.slash.fill" : "speaker.fill").foregroundStyle(store.muted ? accent : mutedInk).frame(width: 20) }.buttonStyle(.plain).help(store.muted ? "Unmute" : "Mute")
                    Slider(value: Binding(get: { store.volume }, set: store.changeVolume), in: 0...100).tint(accent).accessibilityLabel("TV volume").disabled(!store.hasVolume)
                    Image(systemName: "speaker.wave.3.fill").font(.system(size: 11)).foregroundStyle(mutedInk)
                }.disabled(!store.connected)
                HStack {
                    Text(store.muted ? "Muted" : store.hasVolume || !store.connected ? "TV speakers" : "Level unavailable. The buttons still work.").font(.system(size: 10)).foregroundStyle(mutedInk)
                    Spacer()
                    Button { store.volumeStep(false) } label: { Image(systemName: "minus").frame(width: 25, height: 22) }.buttonStyle(PanelButton()).help("Lower volume")
                    Button { store.volumeStep(true) } label: { Image(systemName: "plus").frame(width: 25, height: 22) }.buttonStyle(PanelButton()).help("Raise volume")
                }.disabled(!store.connected)
            }
        }
    }
    private var remotePanel: some View {
        VStack(spacing: 12) {
            PanelCard {
                VStack(spacing: 16) {
                    HStack {
                        Text(store.currentApp).lineLimit(1).fontWeight(.semibold)
                        Spacer()
                        Circle().fill(store.connected ? Color.green : Color.orange).frame(width: 5, height: 5)
                        Text(store.connected ? "Remote ready" : "Not connected").font(.system(size: 9)).foregroundStyle(mutedInk)
                    }
                    HStack(spacing: 15) {
                        VStack(spacing: 12) { remoteButton("house", "Home", "KEY_HOME"); remoteButton("arrow.uturn.backward", "Back", "KEY_RETURN") }
                        ZStack {
                            Circle().fill(Color.white.opacity(0.055)).overlay(Circle().strokeBorder(Color.white.opacity(0.07)))
                            VStack { remoteDirection("chevron.up", "KEY_UP", "Up"); Spacer(); remoteDirection("chevron.down", "KEY_DOWN", "Down") }.padding(6)
                            HStack { remoteDirection("chevron.left", "KEY_LEFT", "Left"); Spacer(); remoteDirection("chevron.right", "KEY_RIGHT", "Right") }.padding(6)
                            Button { store.press("KEY_ENTER") } label: { Text("OK").font(.system(size: 12, weight: .semibold)).frame(width: 46, height: 46).background(Circle().fill(accent.opacity(0.2))).foregroundStyle(accent) }.buttonStyle(.plain).help("Confirm")
                        }.frame(width: 138, height: 138)
                        VStack(spacing: 12) { remoteButton("gearshape", "TV settings", "KEY_MENU"); remoteButton("xmark", "Exit app", "KEY_EXIT") }
                    }.frame(maxWidth: .infinity)
                    HStack(spacing: 7) {
                        mediaButton("backward.fill", "Rewind", "KEY_REWIND")
                        mediaButton("play.fill", "Play", "KEY_PLAY")
                        mediaButton("pause.fill", "Pause", "KEY_PAUSE")
                        mediaButton("stop.fill", "Stop", "KEY_STOP")
                        mediaButton("forward.fill", "Fast forward", "KEY_FF")
                    }
                }.disabled(!store.connected)
            }
            PanelCard {
                VStack(spacing: 9) {
                    HStack { Label("Swipe pad", systemImage: "hand.draw").fontWeight(.semibold); Spacer(); Text(store.pointerMode ? "Drag the pointer · tap to click" : "Swipe to move · tap for OK").font(.system(size: 9)).foregroundStyle(mutedInk) }
                    RoundedRectangle(cornerRadius: 12).fill(accent.opacity(0.065)).overlay(Image(systemName: "hand.draw").font(.system(size: 25, weight: .light)).foregroundStyle(accent.opacity(0.7)))
                        .frame(height: 85).contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 4).onChanged { value in
                            let delta = CGSize(width: value.translation.width - swipeTranslation.width, height: value.translation.height - swipeTranslation.height)
                            swipeTranslation = value.translation
                            store.swipePointer(dx: delta.width, dy: delta.height)
                        }.onEnded { _ in swipeTranslation = .zero; store.endSwipe() })
                        .simultaneousGesture(TapGesture().onEnded { store.tapSwipe() })
                        .accessibilityLabel("TV swipe pad")
                }.disabled(!store.connected)
            }
            audioCard
            HStack(spacing: 8) {
                Button { store.press("KEY_CHDOWN") } label: { Label("Channel −", systemImage: "chevron.down").frame(maxWidth: .infinity).frame(height: 32) }.buttonStyle(PanelButton())
                Button { store.press("KEY_CHUP") } label: { Label("Channel +", systemImage: "chevron.up").frame(maxWidth: .infinity).frame(height: 32) }.buttonStyle(PanelButton())
            }.disabled(!store.connected)
            PanelCard {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Keyboard", systemImage: "keyboard").fontWeight(.semibold)
                    TextField("Type into the open field on your TV", text: $text).textFieldStyle(.roundedBorder).onSubmit(sendText)
                    HStack {
                        Text(store.textInputOpen ? "The TV keyboard is open." : "Open a text field on your TV.").font(.system(size: 10)).foregroundStyle(store.textInputOpen ? accent : mutedInk)
                        Spacer()
                        Button("Send", action: sendText).disabled(text.isEmpty)
                        Button { store.enterText() } label: { Image(systemName: "return") }.help("Finish typing on TV")
                    }
                }.disabled(!store.connected)
            }
            inputsPanel
            Text("Playback controls depend on the open app. Game consoles keep using their own controllers.").font(.system(size: 10)).foregroundStyle(mutedInk)
        }
    }
    private func sendText() { store.sendText(text); text = "" }
    private func remoteDirection(_ symbol: String, _ key: String, _ title: String) -> some View {
        Button { store.press(key) } label: { Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).frame(width: 29, height: 29).contentShape(Rectangle()) }.buttonStyle(.plain).help(title).accessibilityLabel(title)
    }
    private func remoteButton(_ symbol: String, _ title: String, _ key: String) -> some View {
        Button { store.press(key) } label: { Image(systemName: symbol).font(.system(size: 15)).frame(width: 43, height: 42) }.buttonStyle(PanelButton()).help(title).accessibilityLabel(title)
    }
    private func mediaButton(_ symbol: String, _ title: String, _ key: String) -> some View {
        Button { store.media(key) } label: { Image(systemName: symbol).font(.system(size: 11)).frame(maxWidth: .infinity).frame(height: 30) }.buttonStyle(PanelButton()).help(title).accessibilityLabel(title)
    }
    private var appsPanel: some View {
        VStack(spacing: 14) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(mutedInk)
                TextField("Search \(store.shortcuts.count) apps", text: $search).textFieldStyle(.plain)
                if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(mutedInk) }.buttonStyle(.plain) }
            }.padding(11).background(RoundedRectangle(cornerRadius: 11).fill(Color.white.opacity(0.06)))
            if store.appsFromCatalog {
                Text("This TV does not share its app list, so these are common Samsung apps. Right-click an app you do not have to hide it.").font(.system(size: 10)).foregroundStyle(mutedInk).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 9), count: 3), spacing: 9) {
                ForEach(store.shortcuts.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }) { app in
                    let color = BrandTheme.forApp(app.id, title: app.title, icon: AppIcons.url(for: app)).color
                    VStack(spacing: 8) {
                        HStack {
                            Spacer()
                            Button { store.toggleFavorite(app) } label: {
                                Image(systemName: store.favorites.contains(app.id) ? "star.fill" : "star").font(.system(size: 9)).foregroundStyle(store.favorites.contains(app.id) ? color : mutedInk)
                            }.buttonStyle(.plain).help("Favorite \(app.title)").accessibilityLabel("Favorite \(app.title)")
                        }
                        Button { store.launch(app) } label: {
                            VStack(spacing: 10) {
                                AppMark(app: app, size: 43).shadow(color: color.opacity(0.18), radius: 9)
                                Text(app.title).font(.system(size: 10, weight: .medium)).lineLimit(2).frame(height: 26)
                            }.frame(maxWidth: .infinity).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(!store.connected).help("Open \(app.title) on TV")
                        if store.displayForegroundID == app.id { Text("Active").font(.system(size: 9, weight: .semibold)).foregroundStyle(color) }
                        else { Color.clear.frame(height: 11) }
                    }.padding(10).background(RoundedRectangle(cornerRadius: 13).fill(LinearGradient(colors: [color.opacity(0.17), Color.white.opacity(0.035)], startPoint: .topLeading, endPoint: .bottomTrailing)))
                        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(color.opacity(store.displayForegroundID == app.id ? 0.6 : 0.13)))
                        .contextMenu {
                            Button(store.favorites.contains(app.id) ? "Remove from favorites" : "Add to favorites") { store.toggleFavorite(app) }
                            Button("Hide from this list") { store.setHidden(app, true) }
                        }
                }
            }
            HStack(alignment: .top) {
                Text("Click an app to open it on TV. Use the star to add favorites.").font(.system(size: 10)).foregroundStyle(mutedInk)
                Spacer()
                if !store.hiddenApps.isEmpty { Button("Show \(store.hiddenApps.count) hidden") { store.showHiddenApps() }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(accent) }
            }
        }
    }
    private func active(_ input: TVInput) -> Bool { store.displayForegroundID == input.id }
    private func defaultLabel(_ input: TVInput) -> String { input.id == "TV" ? "Live TV" : input.id.replacingOccurrences(of: "HDMI", with: "HDMI ") }
    private func inputRow(_ input: TVInput) -> some View {
        Button { store.input(input) } label: {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(input.label.localizedCaseInsensitiveContains("PS5") ? Color(red: 0.02, green: 0.17, blue: 0.44) : Color.white.opacity(0.055))
                    if input.label.localizedCaseInsensitiveContains("PS5") || input.label.localizedCaseInsensitiveContains("PlayStation") { BrandImage(name: "playstation", width: 24, height: 24) }
                    else if input.label.localizedCaseInsensitiveContains("Chromecast") { BrandImage(name: "googlecast", width: 22, height: 22) }
                    else { Image(systemName: input.id == "TV" ? "antenna.radiowaves.left.and.right" : "cable.connector").font(.system(size: 15)).foregroundStyle(mutedInk) }
                }.frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text(input.label).font(.system(size: 12, weight: .semibold))
                    Text([input.label == defaultLabel(input) ? nil : defaultLabel(input), active(input) ? "Opened from your Mac" : nil].compactMap { $0 }.joined(separator: " · ").ifEmpty(input.id == "TV" ? "Antenna or cable" : "HDMI input"))
                        .font(.system(size: 10)).foregroundStyle(mutedInk)
                }
                Spacer()
                if active(input) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(accent)
                } else { Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(mutedInk) }
            }.padding(.horizontal, 9).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 10).fill(active(input) ? accent.opacity(0.13) : Color.clear))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(active(input) ? accent.opacity(0.32) : Color.clear, lineWidth: 0.7))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(!store.connected).help("Switch TV to \(input.label)")
            .contextMenu { Button("Rename…") { rename(input) } }
            .accessibilityAddTraits(active(input) ? .isSelected : [])
    }
    private func rename(_ input: TVInput) {
        let alert = NSAlert()
        alert.messageText = "Rename \(defaultLabel(input))"
        alert.informativeText = "Name it after what is plugged in, such as PS5 or Chromecast. Leave it empty to use the default name."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = input.label == defaultLabel(input) ? "" : input.label
        field.placeholderString = defaultLabel(input)
        alert.accessoryView = field
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        NSApplication.shared.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn { store.renameInput(input, to: field.stringValue) }
    }
    private var inputsPanel: some View {
        VStack(spacing: 12) {
            PanelCard {
                VStack(spacing: 10) {
                    ForEach(store.inputs) { input in inputRow(input) }
                    Button { store.press("KEY_SOURCE") } label: { Label("Open the Source menu", systemImage: "rectangle.on.rectangle").frame(maxWidth: .infinity).frame(height: 30) }
                        .buttonStyle(PanelButton()).disabled(!store.connected)
                }
            }
            Text("Select an input to change what your TV displays. Right-click an input to rename it.").font(.system(size: 10)).foregroundStyle(mutedInk)
        }
    }
    private var usagePanel: some View {
        let totals = store.usage(days: usageDays)
        let total = totals.reduce(0) { $0 + $1.seconds }
        return VStack(alignment: .leading, spacing: 14) {
            Picker("Period", selection: $usageDays) { Text("Today").tag(1); Text("7 days").tag(7); Text("30 days").tag(30) }.pickerStyle(.segmented)
            VStack(alignment: .leading, spacing: 7) {
                Text("Screen time").font(.system(size: 11, weight: .semibold)).foregroundStyle(mutedInk)
                Text(duration(total)).font(.system(size: 38, weight: .medium, design: .rounded)).tracking(-1).foregroundStyle(accent)
                Text("Apps and inputs opened from your Mac").font(.system(size: 10)).foregroundStyle(mutedInk)
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(RoundedRectangle(cornerRadius: 14).fill(accent.opacity(0.08)))
            PanelCard {
                VStack(spacing: 17) {
                    ForEach(totals) { item in
                        let app = store.apps.first(where: { $0.id == item.id })
                        let color = BrandTheme.forApp(item.id, title: item.title, icon: app.flatMap(AppIcons.url)).color
                        VStack(spacing: 8) {
                            HStack(spacing: 9) {
                                if let app { AppMark(app: app, size: 26) }
                                else if item.title.localizedCaseInsensitiveContains("PS5") { BrandImage(name: "playstation", width: 26, height: 26) }
                                else { Image(systemName: "tv").foregroundStyle(color).frame(width: 26) }
                                Text(item.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                                Spacer(); Text(duration(item.seconds)).font(.system(size: 10)).foregroundStyle(mutedInk).monospacedDigit()
                            }
                            GeometryReader { geometry in
                                ZStack(alignment: .leading) { Capsule().fill(Color.white.opacity(0.04)); Capsule().fill(color).frame(width: geometry.size.width * CGFloat(item.seconds / max(total, 1))) }
                            }.frame(height: 4)
                        }
                    }
                    if totals.isEmpty { VStack(spacing: 9) { Image(systemName: "chart.bar.xaxis").font(.system(size: 26)).foregroundStyle(accent); Text("Your history starts here").fontWeight(.medium); Text("Open an app or an input from this Mac to start counting.").font(.system(size: 10)).foregroundStyle(mutedInk) }.frame(maxWidth: .infinity).padding(.vertical, 25) }
                }
            }
            Text("Local history. Counts the app or input opened from this Mac while the TV is on and your Mac is awake and connected. Changes made with the TV remote are not seen.").font(.system(size: 10)).foregroundStyle(mutedInk)
        }
    }
    private func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60
        if minutes == 0 { return "\(Int(seconds)) s" }
        return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
    }
    private var mediaPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            PanelCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Image(systemName: "airplay.video").font(.system(size: 26, weight: .light)).foregroundStyle(accent)
                        VStack(alignment: .leading, spacing: 3) { Text("Your Mac, on the big screen").font(.system(size: 14, weight: .semibold)); Text("Screen mirroring with AirPlay").font(.system(size: 10)).foregroundStyle(mutedInk) }
                    }
                    Text("In Control Center on your Mac, open Screen Mirroring and choose “\(store.name)”. Samsung TVs from 2018 on support AirPlay 2. You can also use the TV as a second display in Displays settings.").font(.system(size: 11)).foregroundStyle(mutedInk).fixedSize(horizontal: false, vertical: true)
                    Button { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension")!) } label: { Label("Open Displays settings", systemImage: "arrow.up.right") }.buttonStyle(.plain).foregroundStyle(accent)
                }
            }
            PanelCard {
                VStack(alignment: .leading, spacing: 14) {
                    Label("Send a file", systemImage: "play.tv").font(.system(size: 14, weight: .semibold))
                    if let file = store.mediaFile {
                        HStack(spacing: 10) {
                            Image(systemName: "doc.richtext").font(.system(size: 23)).foregroundStyle(accent)
                            VStack(alignment: .leading, spacing: 4) { Text(file.lastPathComponent).fontWeight(.medium).lineLimit(2); Text(file.pathExtension.uppercased()).font(.system(size: 9)).foregroundStyle(mutedInk) }
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(RoundedRectangle(cornerRadius: 10).fill(accent.opacity(0.08)))
                    }
                    Text(store.mediaStatus).font(.system(size: 10)).foregroundStyle(mutedInk).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Choose file") { store.chooseMedia() }.disabled(store.mediaBusy)
                        Spacer()
                        Button(store.mediaBusy ? "Sending…" : "Play on TV") { store.castMedia() }.disabled(!store.connected || store.mediaFile == nil || store.mediaBusy)
                    }.font(.system(size: 10))
                    if store.casting {
                        HStack(spacing: 8) {
                            ForEach([("play.fill", "Play", "Play"), ("pause.fill", "Pause", "Pause"), ("stop.fill", "Stop", "Stop casting")], id: \.1) { symbol, action, title in
                                Button { store.controlCast(action) } label: { Image(systemName: symbol).frame(maxWidth: .infinity).frame(height: 32) }.buttonStyle(PanelButton()).help(title).accessibilityLabel(title)
                            }
                        }.disabled(store.mediaBusy)
                    }
                }
            }
            Text("The file opens on TV when you click Play. Compatibility depends on the format and codec; try H.264 MP4, MP3, or JPEG first. If the TV asks whether to allow this Mac, choose Allow. Keep your Mac awake while casting.").font(.system(size: 10)).foregroundStyle(mutedInk)
        }
    }
    private var logsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SamsungTizen-menubar connections and actions saved on this Mac. Internal TV logs are not available.").font(.system(size: 11)).foregroundStyle(mutedInk)
            PanelCard {
                LazyVStack(alignment: .leading, spacing: 13) {
                    ForEach(store.events.filter { $0.title != "Read" }) { event in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack { Text(event.title).fontWeight(.semibold); Spacer(); Text(event.date, style: .time).foregroundStyle(mutedInk).monospacedDigit() }
                            Text(event.detail).font(.system(size: 10)).foregroundStyle(mutedInk).lineLimit(3).textSelection(.enabled)
                        }.font(.system(size: 11))
                    }
                    if store.events.isEmpty { Text("No events yet.").foregroundStyle(mutedInk).padding(.vertical, 12) }
                }
            }
        }
    }
    private var connectionPanel: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 10) {
                Label(store.status, systemImage: store.pairing ? "checkmark.shield" : "wifi").fontWeight(.semibold)
                Text(store.pairing ? "A request from SamsungTizen-menubar is on your TV screen. Choose Allow with the TV remote." : "Your Mac and TV must be on the same network.").font(.system(size: 11)).foregroundStyle(mutedInk).fixedSize(horizontal: false, vertical: true)
                Button(store.connecting ? "Cancel" : "Connect to TV") {
                    if store.connecting { store.disconnect() }
                    else if store.host.isEmpty { showConnectionSettings() }
                    else { store.connect() }
                }
            }
        }
    }
    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelCard {
                HStack(spacing: 13) {
                    VStack(alignment: .leading, spacing: 7) {
                        BrandImage(name: "samsung", width: 78, height: 12)
                        Text(store.model.isEmpty ? "Samsung TV" : store.model).font(.system(size: 14, weight: .semibold))
                        Text([store.system, store.firmware].filter { !$0.isEmpty }.joined(separator: " · ")).font(.system(size: 10)).foregroundStyle(mutedInk)
                    }
                    Spacer()
                }
            }
            sectionTitle("Connection")
            PanelCard {
                VStack(alignment: .leading, spacing: 11) {
                    Text("Your TV").fontWeight(.semibold)
                    TextField("Name", text: $draftName).textFieldStyle(.roundedBorder)
                    TextField("TV IP address", text: $draftHost).textFieldStyle(.roundedBorder)
                    TextField("Wi-Fi MAC address for wake", text: $draftMAC).textFieldStyle(.roundedBorder)
                    Text("Optional: the MAC address is filled in from the TV and is only needed to wake it.").font(.system(size: 10)).foregroundStyle(mutedInk)
                    Button("Save and connect") {
                        store.disconnect(); store.model = ""; store.system = ""; store.firmware = ""
                        store.host = draftHost.trimmingCharacters(in: .whitespacesAndNewlines)
                        store.name = draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Samsung TV" : draftName.trimmingCharacters(in: .whitespacesAndNewlines)
                        store.mac = draftMAC.trimmingCharacters(in: .whitespacesAndNewlines); store.connect(); settings = false
                    }.disabled(!TizenConnection.localHost(draftHost.trimmingCharacters(in: .whitespacesAndNewlines)) || store.connecting)
                    if !store.host.isEmpty {
                        Button("Forget pairing") { store.forgetPairing() }.disabled(store.connecting)
                    }
                }
            }
            PanelCard {
                VStack(alignment: .leading, spacing: 11) {
                    Button(store.discovering ? "Searching for TVs…" : "Find TVs on your network") { store.discover() }.disabled(store.discovering)
                    ForEach(store.devices) { device in
                        Button { store.select(device); settings = false } label: { HStack { Text(device.name); Spacer(); Text(device.host).foregroundStyle(mutedInk) } }.buttonStyle(.plain)
                    }
                    Text("To wake your TV from your Mac, turn on Power On with Mobile in the TV's network settings.").font(.system(size: 11)).foregroundStyle(mutedInk).fixedSize(horizontal: false, vertical: true)
                }
            }
            PanelCard {
                Stepper(value: Binding(get: { store.hdmiCount }, set: store.setHDMICount), in: 1...4) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("HDMI inputs: \(store.hdmiCount)").fontWeight(.semibold)
                        Text("Match the HDMI ports on the back of your TV.").font(.system(size: 10)).foregroundStyle(mutedInk)
                    }
                }
            }
            DisclosureGroup("Event history", isExpanded: $showEvents) { logsPanel.padding(.top, 10) }.font(.system(size: 11))
        }
    }
    private func showConnectionSettings() {
        draftHost = store.host; draftName = store.name; draftMAC = store.mac
        settings = true
    }
    private var footer: some View {
        HStack(spacing: 6) {
            Circle().fill(store.connected ? .green : store.connecting ? .orange : mutedInk).frame(width: 5, height: 5)
            Text(store.status).font(.system(size: 10)).foregroundStyle(mutedInk)
            Spacer()
            Text(store.model).font(.system(size: 9, weight: .medium)).foregroundStyle(Color.white.opacity(0.3))
            Button {
                if !settings { draftHost = store.host; draftName = store.name; draftMAC = store.mac }
                settings.toggle()
            } label: { Image(systemName: settings ? "xmark" : "slider.horizontal.3").font(.system(size: 12)).foregroundStyle(mutedInk).frame(width: 24, height: 22) }.buttonStyle(.plain).help("App settings")
        }
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
