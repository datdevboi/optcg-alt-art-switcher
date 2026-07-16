import AltArtCore
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct AltArtCoreValidation {
    static func main() throws {
        if CommandLine.arguments.contains("--scan-current") {
            try reportSavedSettingsScan()
            return
        }
        if CommandLine.arguments.contains("--benchmark-current") {
            try benchmarkSavedSettingsScan()
            return
        }
        try validateCardIDParsing()
        try validateBulkRules()
        try validateSettingsStorePersistsLocationsAndSelections()
        try validateIncrementalCollectionIndex()
        try validateScopedApply()
        try validateLiveChoiceEditorBinding()
        try validatePublicDistributionNotices()
        try validateSavedChoiceStability()
        try validateNestedFolderScansBareCardFilenames()
        try validateSmallSourceImagesAreIgnored()
        try validateStaleSavedChoiceNeedsConfirmation()
        try validateNewCardsUseRarity()
        try validateDonSelectionAndApply()
        try validateApplyAndRestore()
        print("All AltArtCore validations passed.")
    }
}

private func benchmarkSavedSettingsScan() throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let settings = SettingsStore().load()
    let store = CollectionIndexStore(root: root)
    let clock = ContinuousClock()
    let coldStart = clock.now
    let cold = try AssetScanner.reconcile(settings: settings, indexStore: store)
    let coldElapsed = coldStart.duration(to: clock.now)
    let cachedStart = clock.now
    let cached = try AssetScanner.cached(settings: settings, indexStore: store)
    let cachedElapsed = cachedStart.duration(to: clock.now)
    let warmStart = clock.now
    let warm = try AssetScanner.reconcile(settings: settings, indexStore: store)
    let warmElapsed = warmStart.duration(to: clock.now)
    print("Cold: \(cold.result.selections.count) cards, \(cold.metrics.filesHashed) files hashed in \(coldElapsed)")
    print("Cached presentation: \(cached?.selections.count ?? 0) cards in \(cachedElapsed)")
    print("Warm: \(warm.result.selections.count) cards, \(warm.metrics.filesHashed) files hashed in \(warmElapsed)")
}

private func validateScopedApply() throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("collection", isDirectory: true)
    let app = root.appendingPathComponent("OPTCGSim.app", isDirectory: true)
    try makeImage(at: source.appendingPathComponent("OP07-099(Alt).png"), width: 80, height: 120, type: .png, color: red)
    try makeImage(at: source.appendingPathComponent("OP07-100(Alt).png"), width: 80, height: 120, type: .png, color: green)
    try makeTargetTree(app: app, id: "OP07-099")
    try makeTargetTree(app: app, id: "OP07-100")
    let scan = try AssetScanner.scan(settings: UserSettings(sourceFolderPath: source.path, simulatorAppPath: app.path))
    let report = try AssetInstaller(store: SettingsStore(root: root.appendingPathComponent("state"))).apply(
        scan: scan,
        request: ApplyRequest(cardIDs: ["OP07-099"], includeDon: false)
    )
    try expect(report.appliedCardIDs == ["OP07-099"], "A scoped apply must report only the requested card")
    try expect(report.filesApplied == 2, "A scoped apply must touch only the requested card's targets")
    let store = SettingsStore(root: root.appendingPathComponent("state"))
    let second = try AssetInstaller(store: store).apply(scan: scan, request: ApplyRequest(cardIDs: ["OP07-100"], includeDon: false))
    try expect(second.appliedCardIDs == ["OP07-100"], "A second scoped apply must remain isolated")
    try expect(AssetInstaller(store: store).restore(simulatorApp: app) == 4, "Restore must cover targets from every scoped apply")
}

private func validateIncrementalCollectionIndex() throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("collection", isDirectory: true)
    let app = root.appendingPathComponent("OPTCGSim.app", isDirectory: true)
    try makeImage(at: source.appendingPathComponent("OP07-099(Alt).png"), width: 80, height: 120, type: .png, color: red)
    try makeTargetTree(app: app, id: "OP07-099")
    let indexStore = CollectionIndexStore(root: root.appendingPathComponent("state", isDirectory: true))
    let settings = UserSettings(sourceFolderPath: source.path, simulatorAppPath: app.path)

    let cold = try AssetScanner.reconcile(settings: settings, indexStore: indexStore)
    try expect(cold.metrics.filesHashed == 1 && cold.metrics.bytesHashed > 0, "A cold scan must hash discovered artwork")
    let warm = try AssetScanner.reconcile(settings: settings, indexStore: indexStore)
    try expect(warm.metrics.filesHashed == 0 && warm.metrics.bytesHashed == 0, "An unchanged warm scan must reuse indexed hashes")
    try expect(warm.result.selections.count == 1, "A warm scan must reconstruct the same library")
    try expect(try AssetScanner.cached(settings: settings, indexStore: indexStore)?.selections.count == 1, "Cached startup must reconstruct the library without reconciliation")

    let artwork = source.appendingPathComponent("OP07-099(Alt).png")
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(2)], ofItemAtPath: artwork.path)
    let changed = try AssetScanner.reconcile(settings: settings, indexStore: indexStore)
    try expect(changed.metrics.filesHashed == 1, "A metadata-changed artwork must be rehashed")
    try FileManager.default.removeItem(at: artwork)
    let deleted = try AssetScanner.reconcile(settings: settings, indexStore: indexStore)
    try expect(deleted.result.selections.isEmpty, "Deleted artwork must be removed from the index")
}

private func reportSavedSettingsScan() throws {
    let result = try AssetScanner.scan(settings: SettingsStore().load())
    let counts = Dictionary(grouping: result.selections, by: \.origin)
    let origins: [(String, Int)] = [
        ("automatic", counts[.automatic]?.count ?? 0),
        ("saved", counts[.saved]?.count ?? 0),
        ("manual", counts[.manual]?.count ?? 0),
        ("unresolved", counts[.unresolved]?.count ?? 0),
        ("stale", counts[.stale]?.count ?? 0)
    ]
    let originCounts = origins.map { entry in "\(entry.0)=\(entry.1)" }.joined(separator: ", ")
    let unresolvedIDs = result.unresolved.map(\.id).joined(separator: ", ")
    let donStatus = result.donSelection.map { "\($0.candidates.count) DON artworks, selected \($0.selected.label)" } ?? "no DON artworks"
    print("Saved-settings scan: \(result.selections.count) card IDs, \(result.selected.count) selected, \(result.unresolved.count) need choices, \(donStatus), \(result.targetCount) target files. Origins: \(originCounts).")
    if !unresolvedIDs.isEmpty { print("Unresolved card IDs: \(unresolvedIDs)") }
}

private func validateCardIDParsing() throws {
    try expect(CardID("OP07-099(Custom).png")?.rawValue == "OP07-099", "OP card ID should parse")
    try expect(CardID("PRB02-014(SP).jpg")?.rawValue == "PRB02-014", "PRB card ID should parse")
    try expect(CardID("P-093(Custom).png")?.rawValue == "P-093", "Promo card ID should parse")
    try expect(CardID("OP07-099.png")?.rawValue == "OP07-099", "Bare card filenames should parse")
    try expect(CardID("OP07-099_small.png") == nil, "The _small suffix should not produce a card candidate")
    try expect(CardID("OP07-099(Alt)_small.jpg") == nil, "The _small suffix should not produce a card candidate after an artwork label")
    try expect(CardID("P-L(Custom).png") == nil, "Unsupported card ID should not parse")
}

private func validateBulkRules() throws {
    let cardID = CardID(rawValue: "OP07-099")!
    let normal  = AltCandidate(cardID: cardID, url: URL(fileURLWithPath: "/tmp/OP07-099(Custom).png"),   relativePath: "Custom Alts/OP07-099(Custom).png",        sha256: "a")
    let standard = AltCandidate(cardID: cardID, url: URL(fileURLWithPath: "/tmp/OP07-099(Alt).png"),    relativePath: "OP07/Alts/OP07-099(Alt).png",           sha256: "b")
    let sp      = AltCandidate(cardID: cardID, url: URL(fileURLWithPath: "/tmp/OP07-099(SP).png"),      relativePath: "OP07/Alts/SP/OP07-099(SP).png",         sha256: "c")
    let manga   = AltCandidate(cardID: cardID, url: URL(fileURLWithPath: "/tmp/OP07-099(Manga).png"),   relativePath: "OP07/Alts/OP07-099(Manga).png",         sha256: "d")
    let winner  = AltCandidate(cardID: cardID, url: URL(fileURLWithPath: "/tmp/OP07-099(Winner).png"),  relativePath: "OP07/Alts/OP07-099(Winner).png",        sha256: "e")
    let championship = AltCandidate(cardID: cardID, url: URL(fileURLWithPath: "/tmp/OP07-099(CS).png"), relativePath: "OP07/Alts/OP07-099(CS).png",            sha256: "h")
    let anniv   = AltCandidate(cardID: cardID, url: URL(fileURLWithPath: "/tmp/OP07-099(3rdAnn).png"), relativePath: "OP07/Alts/OP07-099(3rdAnn).png",       sha256: "f")
    let treasureCup = AltCandidate(cardID: cardID, url: URL(fileURLWithPath: "/tmp/OP07-099(TreasureCup).png"), relativePath: "OP07/Alts/OP07-099(TreasureCup).png", sha256: "i")
    let promo   = AltCandidate(cardID: cardID, url: URL(fileURLWithPath: "/tmp/OP07-099(Promo).png"),   relativePath: "OP07/Alts/OP07-099(Promo).png",         sha256: "g")
    let candidates = [normal, standard, sp, manga, winner, anniv, promo]
    try expect(BulkChoiceRule.firstListed.candidate(from: candidates)?.id == normal.id,    "First-listed bulk rule should be transparent")
    try expect(BulkChoiceRule.preferStandardAlt.candidate(from: candidates)?.id == standard.id, "Standard-alt rule should prefer an exact Alt candidate")
    try expect(BulkChoiceRule.preferCustomArt.candidate(from: candidates)?.id == normal.id, "Custom rule should prefer Custom Alts")
    try expect(BulkChoiceRule.highestRarity.candidate(from: candidates)?.id == manga.id,   "Highest-rarity rule should prefer Manga over all others")
    // Verify tier classification
    try expect(manga.rarity   == .manga,       "Manga detection")
    try expect(sp.rarity      == .sp,          "SP detection")
    try expect(winner.rarity  == .winner,      "Winner detection")
    try expect(championship.rarity == .winner, "CS should classify as Championship")
    try expect(anniv.rarity   == .anniversary, "Anniversary detection")
    try expect(treasureCup.rarity == .anniversary, "TreasureCup should outrank standard Alt Art")
    try expect(standard.rarity == .altArt,     "Alt Art detection")
    try expect(promo.rarity   == .promo,       "Promo detection")
    try expect(normal.rarity  == .altArt,      "Custom should classify as Alt Art")
    // Verify SP > Winner > Alt Art ordering
    try expect(sp.rarity < winner.rarity,      "SP must outrank Winner")
    try expect(sp.rarity < championship.rarity, "SP must outrank Championship")
    try expect(winner.rarity < anniv.rarity,   "Winner must outrank Anniversary")
    try expect(anniv.rarity < standard.rarity, "Anniversary must outrank Alt Art")
    try expect(BulkChoiceRule.highestRarity.candidate(from: [standard, treasureCup])?.id == treasureCup.id, "TreasureCup must be chosen over standard Alt Art")
    try expect(standard.rarity < promo.rarity, "Alt Art must outrank Promo")
}

private func validateSettingsStorePersistsLocationsAndSelections() throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SettingsStore(root: root.appendingPathComponent("state", isDirectory: true))
    let savedChoice = SavedChoice(cardID: "OP07-099", relativeSourcePath: "OP07-099(Manga).png", sourceSHA256: "hash")
    let settings = UserSettings(
        sourceFolderPath: "/collections/one-piece",
        simulatorAppPath: "/Applications/OPTCGSim.app",
        choices: ["OP07-099": savedChoice]
    )

    try store.save(settings)
    let reloaded = store.load()
    try expect(reloaded.sourceFolderPath == settings.sourceFolderPath, "The chosen collection folder must persist across launches")
    try expect(reloaded.simulatorAppPath == settings.simulatorAppPath, "The chosen simulator location must persist across launches")
    try expect(reloaded.choices["OP07-099"] == savedChoice, "A selected card must persist as soon as it is saved")
}

/// Regression guard for the SwiftUI presentation bug: a `sheet(item:)` closure
/// receives the first item as a value, so it cannot be used as the live card
/// queue. The presented view must instead read `choiceEditor` dynamically.
private func validateLiveChoiceEditorBinding() throws {
    let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let appSource = repository.appendingPathComponent("Sources/OPTCGAltArtSwitcher/OPTCGAltArtSwitcherApp.swift")
    let source = try String(contentsOf: appSource, encoding: .utf8)
    try expect(!source.contains(".sheet(item: $model.choiceEditor)"), "The choice queue must not use a snapshot sheet(item:) binding")
    try expect(source.contains(".sheet(isPresented: Binding("), "The choice queue must keep one live sheet open")
    try expect(source.contains("@State private var displayedSelection"), "The choice editor must keep a live displayed card state")
    try expect(source.contains(".onChange(of: model.choiceEditor?.id)"), "The choice editor must update when the queue advances")
    try expect(source.contains("func beginQuickPick"), "New-choice selections must start an explicit quick-pick queue")
    try expect(!source.contains("ChoiceLibraryView"), "Review must be the only workspace")
    try expect(source.contains("@State private var selectedSet"), "Review must retain the selected card set")
    try expect(source.contains("Picker(\"Set\""), "Review must provide a set dropdown")
    try expect(source.contains("All sets"), "Review must include an all-sets filter")
    try expect(source.contains("struct DonChoiceEditor"), "Review must provide a dedicated DON art chooser")
    try expect(source.contains("if let don = scan.donSelection { DonFeature(selection: don) }"), "Review must expose the DON art choice")
    try expect(!source.contains("if let don = model.scan?.donSelection { DonFeature(selection: don) }"), "Review must not duplicate the DON art choice")
    try expect(source.contains("Dictionary(grouping: scan.selected"), "Review preview must group scanned choices by set")
    try expect(source.contains("SetShelf(setCode:"), "Review preview must render each grouped card set")
    try expect(source.contains("@State private var selectedCardID"), "Review must retain card selection state")
    try expect(source.contains("ArtworkImageCache"), "Artwork must be cached for responsive browsing")
    try expect(!source.contains("NSImage(contentsOf:"), "Artwork previews must not decode full images synchronously")
    try expect(source.contains("CGImageSourceCreateThumbnailAtIndex"), "Artwork previews must use downsampled thumbnails")
    try expect(source.contains("cache.totalCostLimit"), "Thumbnail memory must be limited by decoded byte cost")
    try expect(source.contains("Task.detached(priority: .userInitiated)"), "Thumbnail disk work must run outside the main actor")
    try expect(source.contains("TextField(\"Find card ID\""), "Review must provide card-ID search")
    try expect(source.contains("installChanges(cardIDs:"), "Manual artwork selections must install immediately with a scoped request")
    try expect(source.contains("func loadSavedCollectionIfAvailable()"), "The app must load a saved collection automatically")
    try expect(source.contains(".task { model.loadSavedCollectionIfAvailable() }"), "The saved collection must load when the app opens")
    try expect(source.contains("self.loadSavedCollectionIfAvailable()"), "Changing a location must refresh the collection automatically")
    try expect(source.contains("scanAssets(installAfterScan: true)"), "An explicit refresh must apply saved selections to the simulator")
    try expect(source.contains("shouldInstall = installAfterScan && result.unresolved.isEmpty"), "Refresh must wait for a complete scan before installing")
    try expect(source.contains("Label(model.isWorking ? \"Working…\" : \"Refresh & Apply\""), "Manual scanning should clearly explain that it updates the simulator")
    try expect(source.contains("ZStack {"), "The loading state must be layered over the full review area")
    try expect(source.contains("ProgressView().controlSize(.large)"), "The loading indicator must use a centered progress view")
    try expect(source.contains("panel.canChooseFiles = true"), "The simulator picker must allow macOS app bundles")
    try expect(source.contains("panel.canChooseDirectories = false"), "The simulator picker must not treat app bundles as folders")
    try expect(source.contains("panel.treatsFilePackagesAsDirectories = false"), "The simulator picker must keep app bundles selectable")
    try expect(source.contains("locatedSimulatorAppPath(preferredPath:"), "The app should discover OPTCGSim in Applications before showing a picker")
    try expect(!source.contains("Apply Changes"), "Review must not require a separate apply action")
}

private func validatePublicDistributionNotices() throws {
    let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let appSource = try String(contentsOf: repository.appendingPathComponent("Sources/OPTCGAltArtSwitcher/OPTCGAltArtSwitcherApp.swift"), encoding: .utf8)
    let readme = try String(contentsOf: repository.appendingPathComponent("README.md"), encoding: .utf8)
    try expect(appSource.contains("Unofficial utility; not affiliated"), "The app must show its unofficial status")
    try expect(appSource.contains("legally obtained simulator and card-art files"), "The app must explain that users provide their own assets")
    try expect(readme.contains("## Install on your Mac"), "The README must lead non-developers to installation instructions")
    try expect(readme.contains("[latest release](../../releases/latest)"), "The README must link users to the latest release")
    try expect(readme.contains("Because the app is unsigned"), "The README must prepare users for the unsigned-app first launch")
    try expect(readme.contains("GNU General Public License v3.0"), "The README must identify the GPLv3 license")
}

private func validateSavedChoiceStability() throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("collection", isDirectory: true)
    let app = root.appendingPathComponent("OPTCGSim.app", isDirectory: true)
    try makeImage(at: source.appendingPathComponent("OP07-099(Custom).png"), width: 80, height: 120, type: .png, color: red)
    try makeTargetTree(app: app, id: "OP07-099")
    var settings = UserSettings(sourceFolderPath: source.path, simulatorAppPath: app.path)
    var first = try AssetScanner.scan(settings: settings)
    try expect(first.selections.count == 1, "Expected one scanned card")
    try expect(first.selections[0].origin == .automatic, "Single candidate should be automatic")
    guard let firstCandidate = first.selections[0].selected else { throw ValidationError("Automatic candidate was missing") }
    settings.choices["OP07-099"] = SavedChoice(cardID: "OP07-099", relativeSourcePath: firstCandidate.relativePath, sourceSHA256: firstCandidate.sha256)

    try makeImage(at: source.appendingPathComponent("OP07-099(OtherAlt).png"), width: 80, height: 120, type: .png, color: blue)
    first = try AssetScanner.scan(settings: settings)
    try expect(first.unresolved.isEmpty, "A saved choice must remain selected when a new alternative appears")
    try expect(first.selections[0].origin == .saved, "Saved selection should be recognized")
    try expect(first.selections[0].selected?.relativePath == firstCandidate.relativePath, "Expected \(firstCandidate.relativePath), got \(first.selections[0].selected?.relativePath ?? "nothing")")

    try FileManager.default.removeItem(at: source.appendingPathComponent("OP07-099(Custom).png"))
    try makeImage(at: source.appendingPathComponent("OP07-099(Custom).png"), width: 80, height: 120, type: .png, color: green)
    first = try AssetScanner.scan(settings: settings)
    try expect(first.unresolved.isEmpty && first.selections[0].origin == .saved, "An updated saved source should not require reapproval")
}

private func validateNewCardsUseRarity() throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("collection", isDirectory: true)
    let app = root.appendingPathComponent("OPTCGSim.app", isDirectory: true)
    try makeImage(at: source.appendingPathComponent("OP07-099(Alt).png"), width: 80, height: 120, type: .png, color: blue)
    try makeImage(at: source.appendingPathComponent("OP07-099(Manga).png"), width: 80, height: 120, type: .png, color: red)
    try makeTargetTree(app: app, id: "OP07-099")
    let scan = try AssetScanner.scan(settings: UserSettings(sourceFolderPath: source.path, simulatorAppPath: app.path))
    try expect(scan.unresolved.isEmpty, "New cards should not enter New choices when a rarity choice is available")
    try expect(scan.selections[0].selected?.rarity == .manga, "New cards should automatically choose Manga before lower rarities")
}

private func validateNestedFolderScansBareCardFilenames() throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("collection", isDirectory: true)
    let app = root.appendingPathComponent("OPTCGSim.app", isDirectory: true)
    try makeImage(at: source.appendingPathComponent("Alt Cards Jon/OP07-099.png"), width: 80, height: 120, type: .png, color: red)
    try makeTargetTree(app: app, id: "OP07-099")

    let scan = try AssetScanner.scan(settings: UserSettings(sourceFolderPath: source.path, simulatorAppPath: app.path))
    try expect(scan.selections.map(\.cardID.rawValue) == ["OP07-099"], "Bare card filenames in nested folders must be scanned regardless of the folder name")
}

private func validateSmallSourceImagesAreIgnored() throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("collection", isDirectory: true)
    let app = root.appendingPathComponent("OPTCGSim.app", isDirectory: true)
    try makeImage(at: source.appendingPathComponent("Alt Cards Jon/OP07-099(Alt).png"), width: 80, height: 120, type: .png, color: red)
    try makeImage(at: source.appendingPathComponent("Alt Cards Jon/OP07-099(Alt)_small.png"), width: 10, height: 15, type: .png, color: blue)
    try makeTargetTree(app: app, id: "OP07-099")

    let scan = try AssetScanner.scan(settings: UserSettings(sourceFolderPath: source.path, simulatorAppPath: app.path))
    try expect(scan.selections.first?.candidates.count == 1, "_small source images must be ignored instead of becoming duplicate artwork choices")
}

private func validateStaleSavedChoiceNeedsConfirmation() throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("collection", isDirectory: true)
    let app = root.appendingPathComponent("OPTCGSim.app", isDirectory: true)
    try makeImage(at: source.appendingPathComponent("OP07-099(Base).png"), width: 80, height: 120, type: .png, color: blue)
    try makeImage(at: source.appendingPathComponent("OP07-099(Alt).png"), width: 80, height: 120, type: .png, color: green)
    try makeImage(at: source.appendingPathComponent("OP07-099(SP).png"), width: 80, height: 120, type: .png, color: red)
    try makeImage(at: source.appendingPathComponent("OP07-099(Manga).png"), width: 80, height: 120, type: .png, color: red)
    try makeTargetTree(app: app, id: "OP07-099")
    let settings = UserSettings(
        sourceFolderPath: source.path,
        simulatorAppPath: app.path,
        choices: ["OP07-099": SavedChoice(cardID: "OP07-099", relativeSourcePath: "removed/OP07-099(Custom).png", sourceSHA256: "missing")]
    )

    let scan = try AssetScanner.scan(settings: settings)
    try expect(scan.unresolved.count == 1, "A missing saved source must require a deliberate replacement")
    try expect(scan.selections[0].selected == nil, "A stale saved choice must not be overwritten by the rarity rule")
    try expect(scan.selections[0].origin == .stale, "A missing saved source should be marked as stale")
}

private func validateDonSelectionAndApply() throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("collection", isDirectory: true)
    let app = root.appendingPathComponent("OPTCGSim.app", isDirectory: true)
    let firstArt = source.appendingPathComponent("DON!!/First_DON.png")
    let secondArt = source.appendingPathComponent("Custom Alts/Second_DON_Custom.png")
    try makeImage(at: firstArt, width: 80, height: 120, type: .png, color: red)
    try makeImage(at: secondArt, width: 80, height: 120, type: .png, color: green)
    try makeDonTargetTree(app: app)

    var settings = UserSettings(sourceFolderPath: source.path, simulatorAppPath: app.path)
    let initialScan = try AssetScanner.scan(settings: settings)
    guard let initialDon = initialScan.donSelection else { throw ValidationError("Expected DON artwork choices") }
    try expect(initialDon.candidates.count == 2, "All DON artwork should be scanned; found \(initialDon.candidates.map { $0.relativePath }.joined(separator: ", "))")
    try expect(initialDon.targetURLs.count == 3, "One DON selection should target all simulator DON files")
    try expect(initialDon.selected.relativePath == "Custom Alts/Second_DON_Custom.png", "The first listed DON artwork should be selected automatically")

    settings.donChoice = SavedChoice(cardID: "DON", relativeSourcePath: "DON!!/First_DON.png", sourceSHA256: try sha256(of: firstArt))
    let savedScan = try AssetScanner.scan(settings: settings)
    try expect(savedScan.donSelection?.selected.relativePath == "DON!!/First_DON.png", "A saved DON choice should remain selected")
    try expect(savedScan.donSelection?.origin == .saved, "A saved DON choice should be recognized")

    let targets = savedScan.donSelection!.targetURLs
    let originalHashes = try targets.map(sha256)
    let store = SettingsStore(root: root.appendingPathComponent("state", isDirectory: true))
    let report = try AssetInstaller(store: store).apply(scan: savedScan)
    try expect(report.cardsApplied == 0 && report.donApplied, "DON-only apply should report the DON selection")
    try expect(report.filesApplied == 3, "One DON selection should update all three simulator files")
    try expect(try targets.map(sha256) != originalHashes, "All DON targets should change")
    try expect(AssetInstaller(store: store).restore(simulatorApp: app) == 3, "All DON originals should restore")
    try expect(try targets.map(sha256) == originalHashes, "DON targets should restore exactly")
}

private func validateApplyAndRestore() throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("collection", isDirectory: true)
    let app = root.appendingPathComponent("OPTCGSim.app", isDirectory: true)
    let sourceImage = source.appendingPathComponent("OP07-099(Custom).png")
    try makeImage(at: sourceImage, width: 80, height: 120, type: .png, color: red)
    try makeTargetTree(app: app, id: "OP07-099")
    let targetRoot = AssetScanner.cardsRoot(for: app).appendingPathComponent("OP07")
    let full = targetRoot.appendingPathComponent("OP07-099.png")
    let thumbnail = targetRoot.appendingPathComponent("OP07-099_small.jpg")
    let originalFullHash = try sha256(of: full)
    let originalThumbnailHash = try sha256(of: thumbnail)
    let sourceHash = try sha256(of: sourceImage)

    let store = SettingsStore(root: root.appendingPathComponent("state", isDirectory: true))
    let scan = try AssetScanner.scan(settings: UserSettings(sourceFolderPath: source.path, simulatorAppPath: app.path))
    let report = try AssetInstaller(store: store).apply(scan: scan)
    try expect(report.cardsApplied == 1, "One card should be applied")
    try expect(report.filesApplied == 2, "Full image and thumbnail should both be applied")
    try expect(sha256(of: sourceImage) == sourceHash, "Source image must remain unchanged")
    try expect(sha256(of: full) != originalFullHash, "Full image must change")
    try expect(sha256(of: thumbnail) != originalThumbnailHash, "Thumbnail must change")
    try expect(imageSize(full) == CGSize(width: 40, height: 60), "Full image dimensions should be retained")
    try expect(imageSize(thumbnail) == CGSize(width: 10, height: 15), "Thumbnail dimensions should be retained")

    try expect(AssetInstaller(store: store).restore(simulatorApp: app) == 2, "Both original files should restore")
    try expect(sha256(of: full) == originalFullHash, "Full image should restore exactly")
    try expect(sha256(of: thumbnail) == originalThumbnailHash, "Thumbnail should restore exactly")
}

private struct ValidationError: LocalizedError { let message: String; init(_ message: String) { self.message = message }; var errorDescription: String? { message } }
private func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws { guard try condition() else { throw ValidationError(message) } }

private func makeTemporaryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("OPTCGAltArtSwitcherTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func makeTargetTree(app: URL, id: String) throws {
    let set = id.components(separatedBy: "-")[0]
    let folder = AssetScanner.cardsRoot(for: app).appendingPathComponent(set, isDirectory: true)
    try makeImage(at: folder.appendingPathComponent("\(id).png"), width: 40, height: 60, type: .png, color: blue)
    try makeImage(at: folder.appendingPathComponent("\(id)_small.jpg"), width: 10, height: 15, type: .jpeg, color: blue)
}

private func makeDonTargetTree(app: URL) throws {
    let root = AssetScanner.cardsRoot(for: app)
    try makeImage(at: root.appendingPathComponent("Don/Don.png"), width: 40, height: 60, type: .png, color: blue)
    try makeImage(at: root.appendingPathComponent("P/Don.png"), width: 40, height: 60, type: .png, color: blue)
    try makeImage(at: root.appendingPathComponent("P/Don_small.jpg"), width: 10, height: 15, type: .jpeg, color: blue)
}

private func makeImage(at url: URL, width: Int, height: Int, type: UTType, color: CGColor) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CocoaError(.fileWriteUnknown) }
    context.setFillColor(color)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    guard let image = context.makeImage(), let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}

private func imageSize(_ url: URL) -> CGSize {
    let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)! as NSDictionary
    return CGSize(width: properties[kCGImagePropertyPixelWidth] as! Int, height: properties[kCGImagePropertyPixelHeight] as! Int)
}

private let red = CGColor(red: 1, green: 0, blue: 0, alpha: 1)
private let blue = CGColor(red: 0, green: 0, blue: 1, alpha: 1)
private let green = CGColor(red: 0, green: 1, blue: 0, alpha: 1)

// Top-level entry point (replaces @main — required in main.swift for Swift 6)
do {
    try AltArtCoreValidation.main()
} catch {
    fputs("Error: \(error.localizedDescription)\n", stderr)
    exit(1)
}
