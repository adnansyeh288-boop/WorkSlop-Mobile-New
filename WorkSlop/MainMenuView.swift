import SwiftUI

/// The app shell: two glass sliders (top + bottom) switch between
/// Home and the tweak pages — the old All Tweaks menu is gone
/// (owner's design, 2026-10-22). Home keeps the WorkSlop hero, the
/// device gates, the Apply button, and the Settings/Log/Remove
/// menus. Every page keeps its own SkyBackground.
///
/// Screenshot runs deep-link with `-DemoScreen <name>`:
/// home | alltweaks | settings | apply.
enum HomeRoute: Hashable {
    case allTweaks
    case settings
    case log
    case removeTweaks
    case apply
}

struct MainMenuView: View {
    let demoScreen: String?
    @EnvironmentObject private var status: StatusStore
    @EnvironmentObject private var selection: SelectionStore
    @EnvironmentObject private var iconStage: IconThemeStage
    @State private var page: MainPage = .home
    @State private var path: [HomeRoute] = []
    @State private var importing = false
    @State private var pairingNote: String?
    @State private var showTunnelInfo = false
    @State private var showAbout = false
    @ObservedObject private var wireless = WirelessPairing.shared

    init(demoScreen: String? = nil) {
        self.demoScreen = demoScreen
    }

    var body: some View {
        NavigationStack(path: $path) {
            shell
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: HomeRoute.self) { route in
                switch route {
                case .allTweaks: AllTweaksView()
                case .settings: SettingsView()
                case .log: LogView()
                case .removeTweaks: RemoveTweaksView()
                case .apply: ApplyView()
                }
            }
        }
        .onAppear {
            guard path.isEmpty, let s = demoScreen else { return }
            switch s {
            case "alltweaks": page = .liquidGlass
            case "settings": path = [.settings]
            case "apply": path = [.apply]
            default: break
            }
        }
        // `.data` is in the list on purpose: pairing files sitting in a file
        // provider (Telegram/Downloads in Recents) can carry a dynamic UTI
        // that does not conform to the plist types, which greys them out in
        // the picker (seen on iOS 27.0.1). Content is validated on import —
        // `PairingRecord.accept` rejects anything that is not a usable plist.
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: PairingRecord.types + [.propertyList, .data]
        ) { result in
            switch result {
            case .success(let url): flashNote(importPairing(from: url) ?? "Pairing file saved.")
            case .failure: flashNote("Import cancelled.")
            }
        }
        .sheet(isPresented: $showTunnelInfo) { TunnelInfoView() }
        .sheet(isPresented: $showAbout) { AboutInfoView() }
    }

    // MARK: - Shell (two sliders)

    /// The page switch: exactly one page is alive at a time, like
    /// the old push navigation — pages are never stacked or kept
    /// resident side by side.
    private var shell: some View {
        Group {
            switch page {
            case .home:
                homePage
                    .transition(pageTransition)
            case .iconThemes:
                pageShell(title: MainPage.iconThemes.title) {
                    IconThemesView(embedded: true)
                }
                .transition(pageTransition)
            case .statusBar:
                pageShell(title: MainPage.statusBar.title) {
                    StatusBarView(embedded: true)
                }
                .transition(pageTransition)
            case .liquidGlass, .recommend, .springBoard, .appleInternal, .daemons, .posterBoard:
                if let group = page.tweakGroup {
                    pageShell(title: group.id) {
                        TweakListView(group: group, embedded: true)
                    }
                    .transition(pageTransition)
                } else {
                    EmptyView()
                }
            }
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.95), value: page)
    }

    /// Page changes cross-fade instead of cutting hard (owner's fix,
    /// 2026-10-22: transitions felt stiff). Paired with the shell's
    /// spring on `page`.
    ///
    /// Opacity ONLY since 2026-10-23 (owner: transitions still not
    /// smooth enough, worst from Home): the old whisper of scale
    /// (0.98) forced every material surface on BOTH pages — the
    /// ultra-thin cards, the glass sliders, the two animated skies —
    /// to re-rasterise at a changing scale on every frame of the
    /// fade, which is exactly where the frames went. A pure opacity
    /// cross-fade composites what is already rendered. The heavy
    /// half of the fix is on the pages: their lists now mount a beat
    /// after the page itself (see `DeferredMount`), so a first
    /// body build never lands inside the transition's first frame.
    private var pageTransition: AnyTransition {
        .opacity
    }

    /// A tweak page: the page's own view (with its own SkyBackground)
    /// fills the screen; the header + sliders float over it.
    private func pageShell<Content: View>(title: String,
                                          @ViewBuilder content: () -> Content) -> some View {
        ZStack {
            content()
            ShellChrome(title: title, page: $page)
        }
    }

    private var homePage: some View {
        ZStack(alignment: .bottom) {
            SkyBackground()
            ScrollView {
                VStack(spacing: 16) {
                    hero
                    if BuildSupport.current == .partial {
                        partialSupportCard
                    }
                    SliderBar(pages: MainPage.topGroup, selection: $page)
                    deviceCard
                    applyButton
                    menusCard
                    pairingGenerateCard
                    LockBanner()
                    // Clearance so the lock note never hides
                    // behind the floating bottom slider.
                    Color.clear.frame(height: 64)
                }
                .padding()
            }
            .onChange(of: wireless.phase) { newPhase in
                // The library wrote a fresh record to the canonical
                // path: adopt it through the same validation an
                // imported file gets, then start the backend the way
                // a successful import does.
                guard newPhase == .paired else { return }
                adoptGeneratedPairing()
            }
            .onChange(of: pairingNote) { new in
                // Transient notes only: clear after 6s so a stale
                // message never sits on screen.
                guard let current = new else { return }
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(6))
                    if pairingNote == current {
                        pairingNote = nil
                    }
                }
            }
            SliderBar(pages: MainPage.bottomGroup, selection: $page)
                .padding(.horizontal, 14)
                .padding(.bottom, 6)
        }
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(spacing: 8) {
            Image("BrandBlue")
                .resizable()
                .scaledToFit()
                .frame(width: 104, height: 104)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
            HStack(spacing: 6) {
                Text("WorkSlop")
                    .font(.title.weight(.bold))
                Button {
                    showAbout = true
                } label: {
                    Image(systemName: "info.circle")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("about-info")
            }
            Text("\(DeviceStatus.modelOrDash) • \(DeviceInfoEx.versionWithBuild)")
                .font(.footnote)
                .foregroundStyle(.secondary)
            statusLine
        }
        .padding(.top, 8)
    }

    /// The build's support status, directly under the model •
    /// version • build line (owner's design, 2026-10-22): a green
    /// check for Supported, a yellow check for Partially Supported,
    /// a red ! for Not Supported. The level itself is BuildSupport's
    /// existing verdict — this row only displays it.
    private var statusLine: some View {
        HStack(spacing: 6) {
            Image(systemName: BuildSupport.current == .unsupported
                  ? "exclamationmark.circle.fill"
                  : "checkmark.circle.fill")
                .foregroundStyle(statusColor)
            HStack(spacing: 0) {
                Text("Status : ")
                Text(statusWord)
                    .foregroundStyle(statusColor)
            }
            .font(.subheadline.weight(.semibold))
        }
        .accessibilityIdentifier("build-status")
    }

    private var statusColor: Color {
        switch BuildSupport.current {
        case .supported: return .green
        case .partial: return Color(red: 0.93, green: 0.62, blue: 0.10)
        case .unsupported: return .red
        }
    }

    private var statusWord: String {
        switch BuildSupport.current {
        case .supported: return "Supported"
        case .partial: return "Partially Supported"
        case .unsupported: return "Not Supported!!"
        }
    }

    /// Shown only on Partially Supported builds (the iOS 27 line):
    /// the app works, but that path is not device-proven from this
    /// app yet — the warning is the point of the tier.
    private var partialSupportCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Partially supported build")
                    .font(.subheadline.weight(.semibold))
                Text("This device runs \(BuildSupport.currentBuildLabel ?? "iOS 27") (\(DeviceInfoEx.buildNumber)). The iOS 27 path works but is not device-proven from this app yet — applying is at your own risk.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(cardBackground)
        .accessibilityIdentifier("partial-support-warning")
    }

    // MARK: - Device gates

    /// One status card: pairing file and VPN tunnel share a card with a
    /// divider between them. Secondary actions are plain text links
    /// (never gray pills) so the Apply button keeps its visual hierarchy.
    private var deviceCard: some View {
        VStack(spacing: 0) {
            HStack {
                Label {
                    Text("Pairing file")
                } icon: {
                    RowIcon(name: "key.fill")
                }
                Spacer()
                Text(status.pairingImported ? "Imported" : "Not imported")
                    .foregroundStyle(status.pairingImported ? Color.green : .secondary)
                    .fontWeight(status.pairingImported ? .semibold : .regular)
            }
            .padding(.vertical, 12)

            HStack {
                Button(status.pairingImported ? "Re-import pairing file" : "Import pairing file") {
                    importing = true
                }
                .accessibilityIdentifier("import-pairing")
                Spacer()
                if status.pairingImported {
                    Button("Delete", role: .destructive) {
                        PairingStore.delete()
                        status.pairingChanged()
                        flashNote("Pairing file deleted from the app container.")
                    }
                }
            }
            .font(.subheadline)
            .buttonStyle(.plain)
            .padding(.bottom, 12)

            if let pairingNote {
                Text(pairingNote)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 12)
            }

            Divider()

            HStack {
                Label {
                    Text("VPN tunnel")
                } icon: {
                    RowIcon(name: "network")
                }
                Spacer()
                Text(status.vpnDetected ? "DETECTED" : "-")
                    .foregroundStyle(status.vpnDetected ? Color.green : .secondary)
                    .fontWeight(status.vpnDetected ? .semibold : .regular)
            }
            .padding(.vertical, 12)
            .accessibilityIdentifier("status-vpn")

            HStack {
                Button {
                    showTunnelInfo = true
                } label: {
                    Label("What is the VPN tunnel?", systemImage: "info.circle")
                }
                Spacer()
                Button("Refresh") { status.refresh() }
                    .disabled(status.probing)
                    .accessibilityIdentifier("refresh-status")
            }
            .font(.subheadline)
            .buttonStyle(.plain)
            .padding(.bottom, 8)
        }
        .padding(.horizontal, 16)
        .background(cardBackground)
    }

    /// Shows a transient note under the pairing row, then clears it so a
    /// stale message never lingers on screen (the "deleted" note in the
    /// screenshot was from an old action).
    private func flashNote(_ note: String) {
        pairingNote = note
    }

    // MARK: - Get pairing file (wireless, iOS 27)

    /// A separate palette under the menus card (owner's layout call,
    /// 2026-10-22): generate this iPhone's pairing file on-device. The
    /// app advertises itself as a pairable host; the user taps "Pair
    /// with WorkSlop Mobile" in Settings → Privacy & Security →
    /// Developer Mode and enters the PIN shown here. On iOS 26 the
    /// daemon never lists the host, so the button is replaced by the
    /// honest explanation instead of a control that cannot work.
    private var pairingGenerateCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label {
                    Text("Get pairing file")
                } icon: {
                    RowIcon(name: "antenna.radiowaves.left.and.right")
                }
                Spacer()
            }
            .padding(.vertical, 12)

            switch wireless.phase {
            case .idle:
                Text("Generate a pairing file on this iPhone — no computer needed. This iPhone pairs with this app over your local network, and the finished file is saved here.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 12)
                if isWirelessPairingSupported {
                    HStack {
                        Button("Get Pairing File") { wireless.start() }
                            .accessibilityIdentifier("get-pairing-file")
                        Spacer()
                    }
                    .font(.subheadline)
                    .buttonStyle(.plain)
                    .padding(.bottom, 12)
                } else {
                    Text("Needs iOS 27 — the pairing host only appears in Settings on iOS 27 or later. On this iPhone, use Import pairing file above.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 12)
                }
            case .advertising:
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Waiting for this iPhone to connect…")
                            .font(.subheadline)
                    }
                    Text("Open Settings → Privacy & Security → Developer Mode and tap “Pair with \(WirelessPairing.displayName)”. Keep this app open in the background while you do it.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let pin = wireless.pin {
                        Text("PIN: \(pin)")
                            .font(.title3.weight(.bold).monospacedDigit())
                        Text("Enter this PIN in the device prompt in Settings.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Cancel", role: .destructive) { wireless.cancel() }
                        Spacer()
                    }
                    .font(.subheadline)
                    .buttonStyle(.plain)
                }
                .padding(.bottom, 12)
            case .paired:
                Text("Pairing complete — saving the generated file…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 12)
            case .failed(let message):
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 12)
                HStack {
                    Button("Dismiss") { wireless.reset() }
                    Spacer()
                }
                .font(.subheadline)
                .buttonStyle(.plain)
                .padding(.bottom, 12)
            }
        }
        .padding(.horizontal, 16)
        .background(cardBackground)
    }

    private var isWirelessPairingSupported: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
    }

    /// Adopt the record the pairing library just wrote, through
    /// `PairingRecord.adoptFromDisk` (the same validation an imported
    /// file gets), then refresh status and start the backend exactly
    /// the way a successful import does.
    private func adoptGeneratedPairing() {
        do {
            _ = try PairingRecord.adoptFromDisk()
            status.pairingChanged()
            BackendBootstrap.start()
            flashNote("Pairing file generated on this iPhone and saved.")
        } catch {
            flashNote(error.localizedDescription)
        }
        wireless.reset()
    }

    // MARK: - Apply

    private var applyButton: some View {
        Button {
            path.append(.apply)
        } label: {
            Text(applyLabel)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!canApply)
        .accessibilityIdentifier("apply-button")
    }

    private var canApply: Bool {
        var statusBar = StatusBarSelection()
        if let stored = StatusBarPreferences.storedSelection() {
            statusBar.restore(from: stored)
        }
        return status.unlocked && (!selection.staged.isEmpty
            || !iconStage.staged.isEmpty || statusBar.isActive)
    }

    private var applyLabel: String {
        // The REAL deliverable count: every spec of every staged
        // feature (one daemon-group toggle can be dozens of tweaks),
        // plus icon themes and the status bar overrides when active —
        // not the raw number of staged feature IDs.
        var statusBar = StatusBarSelection()
        if let stored = StatusBarPreferences.storedSelection() {
            statusBar.restore(from: stored)
        }
        let total = ApplyCounter.total(
            staged: selection.staged,
            iconCount: iconStage.staged.count,
            statusBarActive: statusBar.isActive,
            statusBarCount: statusBar.overrides.activeCount)
        if total == 0 { return "Apply (stage tweaks first)" }
        if !status.pairingImported { return "Apply (import pairing file first)" }
        if !status.vpnDetected { return "Apply (VPN tunnel not detected)" }
        return "Apply (\(total) staged)"
    }

    // MARK: - Menus

    /// Native-style navigation rows: representative SF Symbols, a
    /// disclosure chevron, clean dividers. Plain Buttons pushing onto
    /// the NavigationStack path (not NavigationLink) so the whole row
    /// is always tappable - contentShape makes even the empty Spacer
    /// area hit-testable.
    private var menusCard: some View {
        VStack(spacing: 0) {
            Button {
                path.append(.settings)
            } label: {
                HStack {
                    Label {
                        Text("Settings")
                    } icon: {
                        RowIcon(name: "gear")
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("menu-settings")
            Divider()
                .padding(.leading, 46)
            Button {
                path.append(.log)
            } label: {
                HStack {
                    Label {
                        Text("Log")
                    } icon: {
                        RowIcon(name: "doc.text")
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("menu-log")
            Divider()
                .padding(.leading, 46)
            Button {
                path.append(.removeTweaks)
            } label: {
                HStack {
                    Label {
                        Text("Remove Tweaks")
                    } icon: {
                        RowIcon(name: "trash")
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("menu-remove-tweaks")
        }
        .padding(.horizontal, 16)
        .background(cardBackground)
    }

    /// Blue-tinted reflective glass card: ultra-thin material keeps the
    /// blur over the animated sky, a translucent blue wash pulls it into
    /// the WorkSlop blue UI family, and a white top sheen gives the
    /// glass reflection. Kept light (never opaque) so text stays
    /// readable. (All ShapeStyles are iOS 15/16-safe.)
    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                .white.opacity(0.32),
                                .blue.opacity(0.08),
                                .blue.opacity(0.22),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            )
            .shadow(color: .blue.opacity(0.14), radius: 8, y: 3)
    }

    // MARK: - Pairing import

    private func importPairing(from url: URL) -> String? {
        // The backend's acceptance path validates the content (an XML
        // plist pairing record) itself and names the problem when it
        // refuses — the extension is not judged here.
        if let problem = PairingStore.importFile(at: url) {
            return problem
        }
        status.pairingChanged()
        BackendBootstrap.start()
        return "Pairing file saved."
    }
}

// MARK: - About / risks / how-to

/// What the (i) button next to the WorkSlop title opens: the honest
/// risks, the steps to use the app, and how the iOS 26 and iOS 27
/// methods differ. English only - translations live in
/// Localizable.xcstrings and are handled separately.
struct AboutInfoView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Applying tweaks on iOS 27 is experimental and risky. iOS 27 can put your iPhone into a BOOTLOOP (stuck on the Apple logo, will not start).")
                    Text("On iOS 27 a full protective backup of your data is taken before anything is written, but a backup cannot undo every kind of damage. The owner of this software (adnan.120hz) is NOT responsible for any damage, bootloop, or data loss.")
                    Text("Your device backup must NOT be encrypted, otherwise the apply is refused before anything is written.")
                    Text("Never force-quit the app while an apply runs: cancelling is best-effort, and a restore already in flight may finish or stop part-way.")
                } header: {
                    Text("Risks")
                }

                Section {
                    Text("1. Get a pairing file on this screen: import one from a computer (iDevice Pair / Apple Configurator) or a pairing app — or, on iOS 27, use the Get pairing file palette below the menus and generate it on this iPhone. Without a pairing file nothing can be delivered.")
                    Text("2. Start a loopback VPN tunnel using LocalDevVPN until the VPN tunnel row above says DETECTED. This is not an internet VPN - no traffic leaves your iPhone.")
                    Text("3. Pick a category from the sliders at the top and bottom of the Home screen, and stage the tweaks you want with the toggles.")
                    Text("4. Back on Home, tap Apply and follow the progress. When it finishes, restart your iPhone manually and check the tweaks.")
                } header: {
                    Text("How to use")
                }

                Section {
                    Text("iOS 26: partial (sparse) restore. Only the staged files are delivered - no full backup, no wipe, no reboot by the app.")
                    Text("iOS 27: a protective backup of all your data is taken first, the tweaks are injected into it, and the modified backup is restored. The app does not reboot the phone - restart it yourself afterwards. If it ever gets stuck on the Apple logo, force-restart it (Volume Up, Volume Down, hold the Side button).")
                } header: {
                    Text("iOS 26 vs iOS 27")
                }
            }
            .navigationTitle("About WorkSlop")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
