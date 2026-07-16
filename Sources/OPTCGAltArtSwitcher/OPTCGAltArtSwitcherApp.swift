import AltArtCore
import AppKit
import SwiftUI

@main
struct OPTCGAltArtSwitcherApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 980, minHeight: 650)
        }
        .windowStyle(.titleBar)
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var settings: UserSettings
    @Published var scan: ScanResult?
    @Published var isWorking = false
    @Published var activityLabel = ""
    @Published var message: String?
    @Published var error: String?
    @Published var choiceEditor: CardSelection?
    @Published var donEditor: DonSelection?
    @Published var showRestoreConfirmation = false
    @Published var batchSelectedIDs: Set<String> = []
    @Published var batchChoiceRule: BulkChoiceRule = .highestRarity
    @Published private(set) var quickPickActive = false

    let store = SettingsStore()

    init() {
        settings = store.load()
        let locatedPath = Self.locatedSimulatorAppPath(preferredPath: settings.simulatorAppPath)
        if locatedPath != settings.simulatorAppPath {
            settings.simulatorAppPath = locatedPath
            persistSettings()
        }
    }

    /// Restores the user's saved collection without asking them to scan again.
    /// Invalid default paths are intentionally quiet: the location controls show
    /// what still needs to be chosen instead of presenting an error on launch.
    func loadSavedCollectionIfAvailable() {
        guard !isWorking, savedLocationsAreAvailable else { return }
        scanAssets()
    }

    func chooseSourceFolder() {
        chooseFolder(current: settings.sourceFolderPath) {
            guard self.settings.sourceFolderPath != $0 else { return }
            self.settings.sourceFolderPath = $0
            // Preferences refer to files relative to the selected collection,
            // so they must not be carried to a different collection.
            self.settings.choices.removeAll()
            self.settings.donChoice = nil
            self.persistSettings()
            self.loadSavedCollectionIfAvailable()
        }
    }

    func chooseSimulatorApp() {
        chooseApp(current: settings.simulatorAppPath) {
            guard self.settings.simulatorAppPath != $0 else { return }
            self.settings.simulatorAppPath = $0
            self.persistSettings()
            self.loadSavedCollectionIfAvailable()
        }
    }

    func scanAssets(force: Bool = false, installAfterScan: Bool = false) {
        guard force || !isWorking else { return }
        persistSettings()
        isWorking = true; activityLabel = "Scanning card artwork…"; error = nil; message = nil
        let settings = self.settings
        Task {
            var shouldInstall = false
            do {
                let result = try await Task.detached { try AssetScanner.scan(settings: settings) }.value
                var changedPreferences = false
                for selection in result.selections {
                    guard let candidate = selection.selected else { continue }
                    let saved = self.settings.choices[selection.cardID.rawValue]
                    if selection.origin == .automatic || (saved?.relativeSourcePath == candidate.relativePath && saved?.sourceSHA256 != candidate.sha256) {
                        self.settings.choices[selection.cardID.rawValue] = SavedChoice(cardID: selection.cardID.rawValue, relativeSourcePath: candidate.relativePath, sourceSHA256: candidate.sha256)
                        changedPreferences = true
                    }
                }
                if let don = result.donSelection {
                    let saved = self.settings.donChoice
                    if don.origin == .automatic || (saved?.relativeSourcePath == don.selected.relativePath && saved?.sourceSHA256 != don.selected.sha256) {
                        self.settings.donChoice = SavedChoice(cardID: "DON", relativeSourcePath: don.selected.relativePath, sourceSHA256: don.selected.sha256)
                        changedPreferences = true
                    }
                }
                if changedPreferences { self.persistSettings() }
                scan = result
                batchSelectedIDs = Set(result.unresolved.map { $0.id })
                message = nil
                // An explicit refresh is also the user's request to bring the
                // simulator up to date. Applying the full saved selection
                // covers cards detected on this scan and any that were found
                // by an earlier scan before this behavior existed.
                shouldInstall = installAfterScan && result.unresolved.isEmpty
            } catch { self.error = error.localizedDescription }
            self.isWorking = false
            self.activityLabel = ""
            if shouldInstall { installChanges() }
        }
    }

    func select(_ candidate: AltCandidate, for selection: CardSelection) {
        let advancesChoiceQueue = quickPickActive && selection.selected == nil
        settings.choices[selection.cardID.rawValue] = SavedChoice(cardID: selection.cardID.rawValue, relativeSourcePath: candidate.relativePath, sourceSHA256: candidate.sha256)
        persistSettings()
        if var result = scan, let index = result.selections.firstIndex(where: { $0.cardID == selection.cardID }) {
            result.selections[index].selected = candidate
            result.selections[index].origin = .manual
            let remaining = result.unresolved
            scan = result
            if advancesChoiceQueue {
                choiceEditor = remaining.first(where: { $0.cardID > selection.cardID }) ?? remaining.first
                if choiceEditor == nil {
                    quickPickActive = false
                    message = "All cards now have an artwork preference. Installing your choices…"
                }
            } else {
                choiceEditor = nil
            }
        } else {
            choiceEditor = nil
        }
        batchSelectedIDs.remove(selection.id)
        installChanges()
    }

    func beginQuickPick(at selection: CardSelection) {
        quickPickActive = true
        choiceEditor = selection
    }

    func openChoiceEditor(for selection: CardSelection) {
        quickPickActive = false
        choiceEditor = selection
    }

    func cancelChoiceEditor() {
        quickPickActive = false
        choiceEditor = nil
    }

    func openDonEditor() { donEditor = scan?.donSelection }

    func selectDon(_ candidate: DonCandidate) {
        settings.donChoice = SavedChoice(cardID: "DON", relativeSourcePath: candidate.relativePath, sourceSHA256: candidate.sha256)
        persistSettings()
        if var result = scan, var selection = result.donSelection {
            selection.selected = candidate
            selection.origin = .manual
            result.donSelection = selection
            scan = result
        }
        donEditor = nil
        installChanges()
    }

    func cancelDonEditor() { donEditor = nil }

    var batchSelectedUnresolvedCount: Int {
        guard let scan else { return 0 }
        return scan.unresolved.filter { batchSelectedIDs.contains($0.id) }.count
    }

    func setBatchSelection(_ selection: CardSelection, enabled: Bool) {
        if enabled { batchSelectedIDs.insert(selection.id) }
        else { batchSelectedIDs.remove(selection.id) }
    }

    func selectAllUnresolved() {
        batchSelectedIDs = Set(scan?.unresolved.map { $0.id } ?? [])
    }

    func clearBatchSelection() { batchSelectedIDs.removeAll() }

    func resolveBatch() {
        guard var result = scan else { return }
        var resolved = 0
        for index in result.selections.indices {
            let selection = result.selections[index]
            guard selection.selected == nil,
                  batchSelectedIDs.contains(selection.id),
                  let candidate = batchChoiceRule.candidate(from: selection.candidates) else { continue }
            result.selections[index].selected = candidate
            result.selections[index].origin = .manual
            settings.choices[selection.cardID.rawValue] = SavedChoice(cardID: selection.cardID.rawValue, relativeSourcePath: candidate.relativePath, sourceSHA256: candidate.sha256)
            resolved += 1
        }
        guard resolved > 0 else { return }
        persistSettings()
        scan = result
        batchSelectedIDs = Set(result.unresolved.map { $0.id })
        message = "Saved artwork choices for \(resolved) cards. Installing your choices…"
        installChanges()
    }

    private func installChanges() {
        guard let scan, scan.unresolved.isEmpty, !isWorking else { return }
        isWorking = true; activityLabel = "Installing selected artwork…"; error = nil; message = nil
        let store = self.store
        Task {
            do {
                let report = try await Task.detached { try AssetInstaller(store: store).apply(scan: scan) }.value
                let donDescription = report.donApplied ? " plus your DON card" : ""
                message = "Installed \(report.cardsApplied) card choices\(donDescription) across \(report.filesApplied) simulator files. Originals are backed up."
                scanAssets(force: true)
            } catch { self.error = error.localizedDescription; self.isWorking = false; self.activityLabel = "" }
        }
    }

    func restore() {
        isWorking = true; activityLabel = "Restoring original artwork…"; error = nil; message = nil
        let simulator = URL(fileURLWithPath: settings.simulatorAppPath)
        let store = self.store
        Task {
            do {
                let restored = try await Task.detached { try AssetInstaller(store: store).restore(simulatorApp: simulator) }.value
                message = "Restored \(restored) original simulator files."
                scanAssets(force: true)
            } catch { self.error = error.localizedDescription; self.isWorking = false; self.activityLabel = "" }
        }
    }

    private func persistSettings() { try? store.save(settings) }

    private var savedLocationsAreAvailable: Bool {
        let sourceExists = FileManager.default.fileExists(atPath: settings.sourceFolderPath)
        let cardsRoot = AssetScanner.cardsRoot(for: URL(fileURLWithPath: settings.simulatorAppPath, isDirectory: true))
        return sourceExists && FileManager.default.fileExists(atPath: cardsRoot.path)
    }

    private func chooseFolder(current: String, completion: @escaping (String) -> Void) {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false; panel.directoryURL = URL(fileURLWithPath: current)
        if panel.runModal() == .OK, let url = panel.url { completion(url.path) }
    }

    private func chooseApp(current: String, completion: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        // macOS app bundles are file packages. Treating them as directories
        // makes them appear disabled in an app-only open panel.
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.prompt = "Choose Simulator"
        let preferredPath = Self.locatedSimulatorAppPath(preferredPath: current)
        panel.directoryURL = URL(fileURLWithPath: preferredPath).deletingLastPathComponent()
        panel.nameFieldStringValue = URL(fileURLWithPath: preferredPath).lastPathComponent
        if panel.runModal() == .OK, let url = panel.url { completion(url.path) }
    }

    /// Prefer the prior selection, then the two standard macOS Applications
    /// locations. This gets most users to OPTCGSim without opening a picker.
    private static func locatedSimulatorAppPath(preferredPath: String) -> String {
        let fileManager = FileManager.default
        let candidates = [
            preferredPath,
            "/Applications/OPTCGSim.app",
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications/OPTCGSim.app").path
        ]
        return candidates.first(where: { fileManager.fileExists(atPath: $0) }) ?? preferredPath
    }
}

private enum HybridTheme {
    static let shell = Color(red: 0.045, green: 0.065, blue: 0.090)
    static let sidebar = Color(red: 0.060, green: 0.090, blue: 0.125)
    static let canvas = Color(red: 0.075, green: 0.095, blue: 0.125)
    static let surface = Color(red: 0.100, green: 0.125, blue: 0.160)
    static let raised = Color(red: 0.125, green: 0.150, blue: 0.190)
    static let gold = Color(red: 0.840, green: 0.620, blue: 0.245)
    static let paleGold = Color(red: 0.950, green: 0.825, blue: 0.510)
    static let success = Color(red: 0.500, green: 0.780, blue: 0.570)
    static let warning = Color(red: 0.945, green: 0.620, blue: 0.245)
    static let line = Color.white.opacity(0.10)
    static let secondaryText = Color.white.opacity(0.62)
}

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            HybridSidebar()
                .frame(width: 220)
            Rectangle().fill(HybridTheme.line).frame(width: 1)
            ReviewView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(HybridTheme.canvas)
        }
        .background(HybridTheme.shell)
        .preferredColorScheme(.dark)
        .overlay(alignment: .topTrailing) {
            if let error = model.error { Banner(text: error, color: .red) }
            else if let message = model.message { Banner(text: message, color: HybridTheme.success) }
        }
        .sheet(isPresented: Binding(
            get: { model.choiceEditor != nil },
            set: { isPresented in if !isPresented { model.cancelChoiceEditor() } }
        )) {
            ChoiceEditor()
        }
        .sheet(isPresented: Binding(
            get: { model.donEditor != nil },
            set: { isPresented in if !isPresented { model.cancelDonEditor() } }
        )) {
            DonChoiceEditor()
        }
        .confirmationDialog("Restore original artwork?", isPresented: $model.showRestoreConfirmation, titleVisibility: .visible) {
            Button("Restore originals", role: .destructive) { model.restore() }
        } message: { Text("This replaces the current alt art with the saved original simulator files.") }
        .task { model.loadSavedCollectionIfAvailable() }
    }
}

private struct HybridSidebar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "rectangle.stack.fill")
                    .font(.title2)
                    .foregroundStyle(HybridTheme.gold)
                VStack(alignment: .leading, spacing: 1) {
                    Text("ALT ART").font(.caption.weight(.bold)).tracking(1.5)
                    Text("Switcher").font(.title3.weight(.semibold))
                }
            }
            .padding(.horizontal, 14)

            Divider().overlay(HybridTheme.line)

            ConnectionControl(title: "COLLECTION", symbol: "folder", path: model.settings.sourceFolderPath, action: model.chooseSourceFolder)
            ConnectionControl(title: "SIMULATOR", symbol: "app", path: model.settings.simulatorAppPath, action: model.chooseSimulatorApp)

            Button { model.scanAssets(installAfterScan: true) } label: {
                Label(model.isWorking ? "Working…" : "Refresh & Apply", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
            }
            .buttonStyle(GoldButtonStyle())
            .keyboardShortcut("r")
            .disabled(model.isWorking)

            ReadinessPanel()
            Spacer(minLength: 8)

            Button { model.showRestoreConfirmation = true } label: {
                Label("Restore Originals", systemImage: "arrow.uturn.backward")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(model.isWorking)

        }
        .padding(14)
        .background(HybridTheme.sidebar)
    }
}

private struct ConnectionControl: View {
    let title: String
    let symbol: String
    let path: String
    let action: () -> Void

    private var exists: Bool { FileManager.default.fileExists(atPath: path) }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.caption2.weight(.bold)).tracking(1.1).foregroundStyle(HybridTheme.secondaryText)
                HStack(spacing: 8) {
                    Image(systemName: symbol).foregroundStyle(HybridTheme.gold)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(URL(fileURLWithPath: path).lastPathComponent)
                            .font(.callout.weight(.medium)).lineLimit(1)
                        Text(path).font(.caption2).foregroundStyle(HybridTheme.secondaryText).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 2)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(HybridTheme.secondaryText)
                }
                Label(exists ? "Located" : "Location not found", systemImage: exists ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.caption2).foregroundStyle(exists ? HybridTheme.success : HybridTheme.warning)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Choose (title.lowercased()) location")
    }
}

private struct ReadinessPanel: View {
    @EnvironmentObject private var model: AppModel

    private var title: String {
        guard let scan = model.scan else { return "Ready to Scan" }
        return scan.unresolved.isEmpty ? "Ready" : "Needs Attention"
    }

    private var detail: String {
        guard let scan = model.scan else { return "Choose locations, then scan your collection." }
        if scan.unresolved.isEmpty { return "\(scan.selected.count) card choices are ready to install when changed." }
        return "Resolve \(scan.unresolved.count) missing choice\(scan.unresolved.count == 1 ? "" : "s") before they can be installed."
    }

    private var color: Color {
        guard let scan = model.scan else { return HybridTheme.gold }
        return scan.unresolved.isEmpty ? HybridTheme.success : HybridTheme.warning
    }

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: model.scan?.unresolved.isEmpty == true ? "checkmark.circle.fill" : "sparkle.magnifyingglass")
                .font(.system(size: 30)).foregroundStyle(color)
            Text(title).font(.headline).foregroundStyle(color)
            Text(detail).font(.caption).foregroundStyle(HybridTheme.secondaryText).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(12)
        .background(HybridTheme.shell.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(color.opacity(0.35)))
    }
}

private struct GoldButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .fontWeight(.semibold)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 36)
            .foregroundStyle(isEnabled ? HybridTheme.shell : Color.white.opacity(0.38))
            .background(isEnabled ? HybridTheme.gold.opacity(configuration.isPressed ? 0.78 : 1) : HybridTheme.raised)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(isEnabled ? HybridTheme.paleGold.opacity(0.50) : HybridTheme.line))
    }
}

struct ReviewView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(
                    eyebrow: "INSTALLATION REVIEW",
                    title: "Your collection, ready for the simulator",
                    detail: "Saved choices are reused automatically. Changes you make here install right away."
                )
                if let scan = model.scan {
                    ScanSummary(scan: scan)
                } else {
                    EmptyState(title: "Loading your collection", image: "photo.stack", detail: "Your saved collection will load automatically when the app opens.")
                        .padding(24)
                }
            }

            if model.isWorking {
                Color.black.opacity(0.28)
                    .ignoresSafeArea()
                VStack(spacing: 12) {
                    ProgressView().controlSize(.large).tint(HybridTheme.gold)
                    Text(model.activityLabel)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 22)
                .background(HybridTheme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(HybridTheme.line))
                .accessibilityElement(children: .combine)
                .accessibilityLabel(model.activityLabel)
            }
        }
    }
}

private struct PageHeader: View {
    let eyebrow: String
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(eyebrow).font(.caption.weight(.bold)).tracking(1.4).foregroundStyle(HybridTheme.gold)
            Text(title).font(.system(size: 26, weight: .bold, design: .rounded))
            Text(detail).font(.callout).foregroundStyle(HybridTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .background(HybridTheme.shell.opacity(0.30))
        .overlay(alignment: .bottom) { Rectangle().fill(HybridTheme.line).frame(height: 1) }
    }
}

struct ScanSummary: View {
    @EnvironmentObject private var model: AppModel
    let scan: ScanResult
    @State private var selectedCardID: String?
    @State private var selectedSet = "All sets"
    @State private var search = ""
    private let allSets = "All sets"

    private struct PreviewSet: Identifiable {
        let id: String
        let selections: [CardSelection]
    }

    private var previewSets: [PreviewSet] {
        Dictionary(grouping: scan.selected, by: { $0.cardID.setCode })
            .map { PreviewSet(id: $0.key, selections: $0.value.sorted { $0.cardID < $1.cardID }) }
            .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    private var visibleSets: [PreviewSet] {
        selectedSet == allSets ? previewSets : previewSets.filter { $0.id == selectedSet }
    }

    private var filteredSets: [PreviewSet] {
        visibleSets.compactMap { set in
            let selections = set.selections.filter {
                search.isEmpty || $0.cardID.rawValue.localizedCaseInsensitiveContains(search)
            }
            return selections.isEmpty ? nil : PreviewSet(id: set.id, selections: selections)
        }
    }

    private var visibleSelections: [CardSelection] {
        filteredSets.flatMap(\.selections)
    }

    private var visibleCardCount: Int {
        visibleSelections.count
    }

    private var selectedCard: CardSelection? {
        visibleSelections.first { $0.id == selectedCardID } ?? visibleSelections.first
    }

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ScanMetrics(scan: scan)
                    HStack(spacing: 12) {
                        Picker("Set", selection: $selectedSet) {
                            Text("\(allSets) (\(scan.selected.count))").tag(allSets)
                            ForEach(previewSets) { set in
                                Text("\(set.id) (\(set.selections.count))").tag(set.id)
                            }
                        }
                        .pickerStyle(.menu)
                        .accessibilityLabel("Card set")
                        TextField("Find card ID", text: $search)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 220)
                        Text("Showing \(visibleCardCount) cards")
                            .font(.callout.weight(.medium))
                            .monospacedDigit()
                            .foregroundStyle(HybridTheme.secondaryText)
                        Spacer()
                    }
                    if let don = scan.donSelection { DonFeature(selection: don) }
                    if !scan.unresolved.isEmpty { UnresolvedPanel(scan: scan) }
                    ForEach(filteredSets) { set in
                        SetShelf(setCode: set.id, selections: set.selections, selectedCardID: $selectedCardID)
                    }
                    if !scan.ignoredFiles.isEmpty {
                        Label("\(scan.ignoredFiles.count) unsupported parenthesized images were skipped.", systemImage: "info.circle")
                            .font(.footnote).foregroundStyle(HybridTheme.secondaryText)
                    }
                }
                .padding(20)
            }
            Rectangle().fill(HybridTheme.line).frame(width: 1)
            ArtworkInspector(selection: selectedCard).frame(width: 245)
        }
        .onAppear { selectedCardID = selectedCardID ?? visibleSelections.first?.id }
        .onChange(of: selectedSet) { _ in
            selectedCardID = visibleSelections.first?.id
        }
        .onChange(of: search) { _ in
            if !visibleSelections.contains(where: { $0.id == selectedCardID }) {
                selectedCardID = visibleSelections.first?.id
            }
        }
    }
}

private struct ScanMetrics: View {
    let scan: ScanResult

    var body: some View {
        HStack(spacing: 0) {
            Metric(value: "\(scan.selections.count)", label: "CARD IDS")
            Divider().frame(height: 34).overlay(HybridTheme.line)
            Metric(value: "\(scan.selected.count)", label: "SELECTED")
            Divider().frame(height: 34).overlay(HybridTheme.line)
            Metric(value: "\(scan.unresolved.count)", label: "NEED ATTENTION", color: scan.unresolved.isEmpty ? .white : HybridTheme.warning)
            Divider().frame(height: 34).overlay(HybridTheme.line)
            Metric(value: "\(scan.targetCount)", label: "FILES TO REPLACE")
        }
        .padding(.vertical, 13)
        .background(HybridTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(HybridTheme.line))
    }
}

private struct UnresolvedPanel: View {
    @EnvironmentObject private var model: AppModel
    let scan: ScanResult

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Unavailable Saved Choices", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline).foregroundStyle(HybridTheme.warning)
                Spacer()
                Button("Select All") { model.selectAllUnresolved() }
                Button("Clear") { model.clearBatchSelection() }
            }
            Text("The saved source files are no longer available. Choose replacements now; every preference remains editable later.")
                .font(.footnote).foregroundStyle(HybridTheme.secondaryText)
            HStack {
                Picker("Replacement rule", selection: $model.batchChoiceRule) {
                    ForEach(BulkChoiceRule.allCases, id: \.self) { rule in Text(rule.title).tag(rule) }
                }
                .pickerStyle(.menu)
                Spacer()
                Button("Choose \(model.batchSelectedUnresolvedCount) Cards") { model.resolveBatch() }
                    .buttonStyle(.borderedProminent).tint(HybridTheme.gold)
                    .disabled(model.batchSelectedUnresolvedCount == 0)
            }
            LazyVStack(spacing: 1) {
                ForEach(scan.unresolved) { selection in
                    HStack {
                        Toggle(isOn: Binding(
                            get: { model.batchSelectedIDs.contains(selection.id) },
                            set: { model.setBatchSelection(selection, enabled: $0) }
                        )) {
                            Text(selection.cardID.rawValue).font(.callout.weight(.semibold)).fontDesign(.monospaced)
                        }
                        .toggleStyle(.checkbox)
                        .accessibilityLabel("Include \(selection.cardID.rawValue) in bulk choice")
                        Text("\(selection.candidates.count) alternatives").font(.caption).foregroundStyle(HybridTheme.secondaryText)
                        Spacer()
                        Button("Choose Manually") { model.beginQuickPick(at: selection) }
                    }
                    .padding(.horizontal, 10).frame(height: 38)
                    .background(HybridTheme.shell.opacity(0.38))
                }
            }
        }
        .padding(14)
        .background(HybridTheme.warning.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(HybridTheme.warning.opacity(0.34)))
    }
}

private struct SetShelf: View {
    let setCode: String
    let selections: [CardSelection]
    @Binding var selectedCardID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(setCode).font(.headline).fontDesign(.monospaced)
                Text("\(selections.count) cards").font(.caption).foregroundStyle(HybridTheme.secondaryText)
                Spacer()
                Text("\(selections.count) / \(selections.count) chosen")
                    .font(.caption.weight(.medium)).monospacedDigit().foregroundStyle(HybridTheme.success)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 10) {
                    ForEach(selections) { selection in
                        ArtworkTile(selection: selection, selected: selectedCardID == selection.id) { selectedCardID = selection.id }
                    }
                }
                .padding(1)
            }
        }
        .padding(14)
        .background(HybridTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(HybridTheme.line))
    }
}

private struct ArtworkTile: View {
    let selection: CardSelection
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                ArtworkImage(url: selection.selected?.url).frame(width: 82, height: 115)
                Text(selection.cardID.rawValue)
                    .font(.caption.weight(.semibold)).fontDesign(.monospaced).lineLimit(1)
                Text(selection.selected?.rarity.title ?? "Needs choice")
                    .font(.caption2).foregroundStyle(selection.selected?.rarity.color ?? HybridTheme.warning).lineLimit(1)
            }
            .frame(width: 82, alignment: .leading)
            .padding(7)
            .background(selected ? HybridTheme.gold.opacity(0.13) : HybridTheme.shell.opacity(0.38))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? HybridTheme.gold : HybridTheme.line, lineWidth: selected ? 2 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(selection.cardID.rawValue), \(selection.selected?.label ?? "needs artwork")")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct ArtworkInspector: View {
    @EnvironmentObject private var model: AppModel
    let selection: CardSelection?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("SELECTED ARTWORK").font(.caption2.weight(.bold)).tracking(1.2).foregroundStyle(HybridTheme.gold)
            if let selection {
                ArtworkImage(url: selection.selected?.url)
                    .aspectRatio(5.0 / 7.0, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                Text(selection.cardID.rawValue).font(.title3.weight(.bold)).fontDesign(.monospaced)
                Text(selection.selected?.label ?? "No artwork selected").font(.callout).foregroundStyle(HybridTheme.secondaryText).lineLimit(2)
                InspectorLine(label: "Rarity", value: selection.selected?.rarity.title ?? "—")
                InspectorLine(label: "Choice", value: originLabel(selection.origin))
                InspectorLine(label: "Targets", value: "\(selection.targetURLs.count) files")
                Spacer()
                Button("Choose Different Artwork") { model.openChoiceEditor(for: selection) }
                    .buttonStyle(GoldButtonStyle()).frame(maxWidth: .infinity)
            } else {
                Spacer()
                EmptyState(title: "Select a card", image: "rectangle.portrait.on.rectangle.portrait", detail: "Choose a card to inspect its current artwork.")
                Spacer()
            }
        }
        .padding(16)
        .background(HybridTheme.shell.opacity(0.46))
    }
}

private struct InspectorLine: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(HybridTheme.secondaryText)
            Spacer()
            Text(value).multilineTextAlignment(.trailing).lineLimit(2)
        }
        .font(.caption)
        .padding(.vertical, 3)
        .overlay(alignment: .bottom) { Rectangle().fill(HybridTheme.line).frame(height: 1) }
    }
}

private func originLabel(_ origin: CardSelection.Origin) -> String {
    switch origin {
    case .automatic: "Automatic"
    case .saved: "Saved"
    case .manual: "Manual"
    case .unresolved: "Needs choice"
    case .stale: "Source missing"
    }
}

private struct DonFeature: View {
    @EnvironmentObject private var model: AppModel
    let selection: DonSelection

    var body: some View {
        HStack(spacing: 14) {
            ArtworkImage(url: selection.selected.url).frame(width: 72, height: 100)
            VStack(alignment: .leading, spacing: 5) {
                Label("DON CARD", systemImage: "sparkles.rectangle.stack.fill")
                    .font(.caption.weight(.bold)).foregroundStyle(HybridTheme.gold)
                Text(selection.selected.label).font(.headline).lineLimit(1)
                Text("One artwork is used for every DON card in the simulator.")
                    .font(.caption).foregroundStyle(HybridTheme.secondaryText)
            }
            Spacer()
            Button("Choose DON Art") { model.openDonEditor() }.buttonStyle(.bordered)
        }
        .padding(14)
        .background(HybridTheme.gold.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(HybridTheme.gold.opacity(0.30)))
    }
}

struct ArtworkImage: View {
    let url: URL?

    var body: some View {
        GeometryReader { proxy in
            Group {
                if let url, let image = ArtworkImageCache.shared.image(at: url) {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "photo")
                        .font(.title2).foregroundStyle(HybridTheme.secondaryText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(HybridTheme.raised)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(HybridTheme.line))
        .accessibilityHidden(true)
    }
}

@MainActor
private final class ArtworkImageCache {
    static let shared = ArtworkImageCache()

    private let cache = NSCache<NSURL, NSImage>()

    private init() {
        cache.countLimit = 400
    }

    func image(at url: URL) -> NSImage? {
        let key = url as NSURL
        if let image = cache.object(forKey: key) { return image }
        guard let image = NSImage(contentsOf: url) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    func removeAll() { cache.removeAllObjects() }
}

struct SelectedArtworkThumbnail: View {
    let candidate: AltCandidate?

    var body: some View {
        ArtworkThumbnail(url: candidate?.url)
    }
}

struct ArtworkThumbnail: View {
    let url: URL?

    var body: some View {
        Group {
            if let url, let image = ArtworkImageCache.shared.image(at: url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.secondary.opacity(0.10))
            }
        }
        .frame(width: 44, height: 62)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.25)))
        .accessibilityHidden(true)
    }
}

struct ChoiceEditor: View {
    @EnvironmentObject private var model: AppModel
    @State private var displayedSelection: CardSelection?

    var body: some View {
        Group {
            if let selection = displayedSelection {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(model.quickPickActive ? "QUICK PICK" : "ARTWORK OPTIONS")
                                .font(.caption.weight(.bold)).tracking(1.2).foregroundStyle(HybridTheme.gold)
                            Text("Choose artwork for \(selection.cardID.rawValue)")
                                .font(.title2.bold()).fontDesign(.rounded)
                                .accessibilityIdentifier("choice-editor-card-id")
                            Text(selection.selected == nil
                                 ? "Choose an artwork to save it and continue to the next missing card."
                                 : "This is saved and installed in the simulator right away.")
                                .font(.callout).foregroundStyle(HybridTheme.secondaryText)
                        }
                        Spacer()
                        Button("Cancel") { model.cancelChoiceEditor() }.keyboardShortcut(.cancelAction)
                    }
                    .padding(20)
                    .background(HybridTheme.shell.opacity(0.55))
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 14)], spacing: 14) {
                            ForEach(selection.candidates) { candidate in CandidateCard(candidate: candidate, selected: selection.selected?.id == candidate.id) { model.select(candidate, for: selection) } }
                        }
                        .padding(20)
                    }
                    .disabled(model.isWorking)
                }
                .frame(minWidth: 700, minHeight: 540)
                .background(HybridTheme.canvas)
                .id(selection.id)
            }
        }
        .onAppear { displayedSelection = model.choiceEditor }
        .onChange(of: model.choiceEditor?.id) { _ in displayedSelection = model.choiceEditor }
    }
}

struct DonChoiceEditor: View {
    @EnvironmentObject private var model: AppModel
    @State private var displayedSelection: DonSelection?

    var body: some View {
        Group {
            if let selection = displayedSelection {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("DON CARD").font(.caption.weight(.bold)).tracking(1.2).foregroundStyle(HybridTheme.gold)
                            Text("Choose DON artwork").font(.title2.bold()).fontDesign(.rounded).accessibilityIdentifier("don-choice-editor")
                            Text("This single choice is used for every DON card in the simulator.")
                                .font(.callout).foregroundStyle(HybridTheme.secondaryText)
                        }
                        Spacer()
                        Button("Cancel") { model.cancelDonEditor() }.keyboardShortcut(.cancelAction)
                    }
                    .padding(20)
                    .background(HybridTheme.shell.opacity(0.55))
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 14)], spacing: 14) {
                            ForEach(selection.candidates) { candidate in
                                DonCandidateCard(candidate: candidate, selected: selection.selected.id == candidate.id) {
                                    model.selectDon(candidate)
                                }
                            }
                        }
                        .padding(20)
                    }
                    .disabled(model.isWorking)
                }
                .frame(minWidth: 700, minHeight: 540)
                .background(HybridTheme.canvas)
                .id(selection.selected.id)
            }
        }
        .onAppear { displayedSelection = model.donEditor }
        .onChange(of: model.donEditor?.selected.id) { _ in displayedSelection = model.donEditor }
    }
}

struct CandidateCard: View {
    let candidate: AltCandidate; let selected: Bool; let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                ArtworkImage(url: candidate.url).aspectRatio(5.0 / 7.0, contentMode: .fit).frame(maxWidth: .infinity)
                Text(candidate.label).lineLimit(2).font(.callout).multilineTextAlignment(.leading)
                Text(candidate.rarity.title).font(.caption.weight(.semibold)).foregroundStyle(candidate.rarity.color)
                Text(candidate.relativePath).lineLimit(1).font(.caption2).foregroundStyle(HybridTheme.secondaryText)
                if selected { Label("Current choice", systemImage: "checkmark.circle.fill").font(.caption.weight(.semibold)).foregroundStyle(HybridTheme.gold) }
            }
            .padding(9).frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? HybridTheme.gold.opacity(0.13) : HybridTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(selected ? HybridTheme.gold : HybridTheme.line, lineWidth: selected ? 2 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Use \(candidate.label) for \(candidate.cardID.rawValue)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct DonCandidateCard: View {
    let candidate: DonCandidate; let selected: Bool; let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                ArtworkImage(url: candidate.url).aspectRatio(5.0 / 7.0, contentMode: .fit).frame(maxWidth: .infinity)
                Text(candidate.label).lineLimit(2).font(.callout).multilineTextAlignment(.leading)
                Text(candidate.relativePath).lineLimit(1).font(.caption2).foregroundStyle(HybridTheme.secondaryText)
                if selected { Label("Current choice", systemImage: "checkmark.circle.fill").font(.caption.weight(.semibold)).foregroundStyle(HybridTheme.gold) }
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? HybridTheme.gold.opacity(0.13) : HybridTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(selected ? HybridTheme.gold : HybridTheme.line, lineWidth: selected ? 2 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Use \(candidate.label) as the DON card artwork")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct Metric: View {
    let value: String
    let label: String
    var color: Color = .white

    var body: some View {
        VStack(spacing: 3) {
            Text(value).font(.title2.bold()).monospacedDigit().foregroundStyle(color)
            Text(label).font(.caption2.weight(.semibold)).foregroundStyle(HybridTheme.secondaryText)
        }
        .frame(maxWidth: .infinity)
    }
}

struct Banner: View {
    let text: String
    let color: Color

    var body: some View {
        Label(text, systemImage: "info.circle.fill")
            .font(.callout.weight(.medium))
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(HybridTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(color.opacity(0.55)))
            .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
            .padding(14)
    }
}

struct EmptyState: View {
    let title: String
    let image: String
    let detail: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: image).font(.system(size: 32)).foregroundStyle(HybridTheme.gold)
            Text(title).font(.headline)
            Text(detail).font(.callout).multilineTextAlignment(.center).foregroundStyle(HybridTheme.secondaryText).frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private extension BulkChoiceRule {
    var title: String {
        switch self {
        case .highestRarity: "Highest rarity: Manga → SP → Winner → Anniversary → Alt Art → Promo → Base"
        case .firstListed: "First listed art (fastest)"
        case .preferStandardAlt: "Prefer exact (Alt) art"
        case .preferCustomArt: "Prefer Custom Alts"
        }
    }
}

private extension ArtworkRarity {
    var title: String {
        switch self {
        case .manga:       "Manga Rare"
        case .sp:          "SP"
        case .winner:      "Winner/Champ"
        case .anniversary: "Anniversary/Treasure"
        case .altArt:      "Alt Art"
        case .promo:       "Promo"
        case .base:        "Base"
        }
    }

    var color: Color {
        switch self {
        case .manga:       .purple
        case .sp:          .orange
        case .winner:      .red
        case .anniversary: .teal
        case .altArt:      .blue
        case .promo:       .cyan
        case .base:        .secondary
        }
    }
}
