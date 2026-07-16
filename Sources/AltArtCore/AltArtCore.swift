import AppKit
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum AltArtError: LocalizedError {
    case invalidSimulator(URL)
    case invalidSource(URL)
    case simulatorIsRunning
    case unresolvedChoices(Int)
    case noRestoreAvailable
    case changedInstallation
    case unsupportedImage(URL)

    public var errorDescription: String? {
        switch self {
        case .invalidSimulator(let url): return "No OPTCGSim card assets were found at \(url.path)."
        case .invalidSource(let url): return "No readable alt-art folder was found at \(url.path)."
        case .simulatorIsRunning: return "Quit OPTCGSim before changing its artwork."
        case .unresolvedChoices(let count): return "Choose artwork for \(count) new card\(count == 1 ? "" : "s") before applying."
        case .noRestoreAvailable: return "There is no applicable backup to restore."
        case .changedInstallation: return "The simulator artwork has changed since this backup was made. Scan and apply first to create a current backup."
        case .unsupportedImage(let url): return "Could not read image data from \(url.lastPathComponent)."
        }
    }
}

public struct CardID: Hashable, Codable, Comparable, Sendable {
    public let rawValue: String

    public init?(_ filename: String) {
        let pattern = "^((?:(?:OP|ST|EB|PRB)[0-9]{2}-[0-9]{3}|P-[0-9]{3}))(?:\\s*\\([^)]*\\))?\\.(?:png|jpe?g)$"
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(filename.startIndex..., in: filename)
        guard let match = expression.firstMatch(in: filename, range: range),
              let idRange = Range(match.range(at: 1), in: filename) else { return nil }
        rawValue = String(filename[idRange]).uppercased()
    }

    public init?(rawValue: String) {
        let pattern = "^(?:(?:OP|ST|EB|PRB)[0-9]{2}-[0-9]{3}|P-[0-9]{3})$"
        guard rawValue.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil else { return nil }
        self.rawValue = rawValue.uppercased()
    }

    public var setCode: String { rawValue.components(separatedBy: "-")[0] }
    public static func < (lhs: CardID, rhs: CardID) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct AltCandidate: Identifiable, Hashable, Sendable {
    public var id: String { relativePath }
    public let cardID: CardID
    public let url: URL
    public let relativePath: String
    public let sha256: String
    public let label: String

    public init(cardID: CardID, url: URL, relativePath: String, sha256: String) {
        self.cardID = cardID
        self.url = url
        self.relativePath = relativePath
        self.sha256 = sha256
        self.label = url.deletingPathExtension().lastPathComponent
    }

    public var rarity: ArtworkRarity {
        let meta = "\(label) \(relativePath)".lowercased()
        let lbl  = label.lowercased()   // filename only — avoids folder-name false positives
        // Tier 1: Manga Rare — iconic manga panel art, rarest pullable treatment
        if meta.contains("manga")  { return .manga }
        // Tier 2: SP (Special Parallel) — wanted-poster style, ~1 per case
        if meta.contains("/sp/") || lbl.contains("(sp)") { return .sp }
        // Tier 3: Winner / Champion — event-exclusive tournament promos, fewest copies
        if lbl.contains("winner") || lbl.contains("champ") || lbl.contains("(cs") || meta.contains("/cs/") { return .winner }
        // Tier 4: Anniversary / Treasure / Premium — limited-run special editions
        if lbl.contains("ann") || lbl.contains("treasure") || lbl.contains("premium") { return .anniversary }
        // Tier 5: Standard Alt Art — use label only so '/Alts/' folder paths don't pollute
        if lbl.contains("alt") || lbl.contains("custom") { return .altArt }
        // Tier 6: Promo — event/magazine promos (widely distributed)
        if lbl.contains("promo") { return .promo }
        // Tier 7: Base — standard card art
        return .base
    }
}

/// Ordered from the rarest treatment to the most ordinary treatment.
/// Ranking based on One Piece TCG collector hierarchy:
///   Manga > SP > Winner/Champ > Anniversary/Treasure > Alt Art > Promo > Base
public enum ArtworkRarity: Int, CaseIterable, Comparable, Sendable, Hashable {
    case manga       = 0  // Manga panel art — rarest pullable
    case sp          = 1  // Special Parallel — ~1 per case
    case winner      = 2  // Tournament Winner/Champion promos — event-exclusive
    case anniversary = 3  // Anniversary, Treasure, Premium editions
    case altArt      = 4  // Standard alternate artwork
    case promo       = 5  // Promotional cards (widely distributed)
    case base        = 6  // Standard card art

    public static func < (lhs: ArtworkRarity, rhs: ArtworkRarity) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A transparent, deterministic rule for resolving a batch of card IDs.
/// Every rule falls back to the first item shown in the chooser, so batch
/// actions are repeatable and any result can still be changed individually.
public enum BulkChoiceRule: String, CaseIterable, Sendable, Hashable {
    case highestRarity
    case firstListed
    case preferStandardAlt
    case preferCustomArt

    public func candidate(from candidates: [AltCandidate]) -> AltCandidate? {
        switch self {
        case .highestRarity:
            return candidates.min { lhs, rhs in
                lhs.rarity == rhs.rarity
                    ? lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
                    : lhs.rarity < rhs.rarity
            }
        case .firstListed:
            return candidates.first
        case .preferStandardAlt:
            return candidates.first(where: { $0.label.localizedCaseInsensitiveContains("(Alt)") }) ?? candidates.first
        case .preferCustomArt:
            return candidates.first(where: {
                $0.relativePath.localizedCaseInsensitiveContains("Custom Alts/") ||
                $0.label.localizedCaseInsensitiveContains("(Custom")
            }) ?? candidates.first
        }
    }
}

public struct SavedChoice: Codable, Hashable, Sendable {
    public let cardID: String
    public let relativeSourcePath: String
    public let sourceSHA256: String

    public init(cardID: String, relativeSourcePath: String, sourceSHA256: String) {
        self.cardID = cardID
        self.relativeSourcePath = relativeSourcePath
        self.sourceSHA256 = sourceSHA256
    }
}

public struct UserSettings: Codable, Sendable {
    public var sourceFolderPath: String
    public var simulatorAppPath: String
    public var choices: [String: SavedChoice]
    public var donChoice: SavedChoice?

    public init(sourceFolderPath: String, simulatorAppPath: String, choices: [String: SavedChoice] = [:], donChoice: SavedChoice? = nil) {
        self.sourceFolderPath = sourceFolderPath
        self.simulatorAppPath = simulatorAppPath
        self.choices = choices
        self.donChoice = donChoice
    }

    public static var `default`: UserSettings {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return UserSettings(
            sourceFolderPath: home + "/Desktop/OP TCG Card Collection",
            simulatorAppPath: "/Applications/OPTCGSim.app"
        )
    }
}

public struct CardSelection: Identifiable, Sendable {
    public enum Origin: Sendable, Equatable { case automatic, saved, manual, unresolved, stale }
    public let cardID: CardID
    public let candidates: [AltCandidate]
    public let targetURLs: [URL]
    public var selected: AltCandidate?
    public var origin: Origin
    public var id: String { cardID.rawValue }
}

public struct DonCandidate: Identifiable, Hashable, Sendable {
    public var id: String { relativePath }
    public let url: URL
    public let relativePath: String
    public let sha256: String
    public let label: String

    public init(url: URL, relativePath: String, sha256: String) {
        self.url = url
        self.relativePath = relativePath
        self.sha256 = sha256
        self.label = url.deletingPathExtension().lastPathComponent
    }
}

public struct DonSelection: Sendable {
    public enum Origin: Sendable, Equatable { case automatic, saved, manual }
    public let candidates: [DonCandidate]
    public let targetURLs: [URL]
    public var selected: DonCandidate
    public var origin: Origin
}

public struct ScanResult: Sendable {
    public let sourceFolder: URL
    public let simulatorApp: URL
    public var selections: [CardSelection]
    public var donSelection: DonSelection?
    public let ignoredFiles: [URL]

    public var unresolved: [CardSelection] { selections.filter { $0.selected == nil } }
    public var selected: [CardSelection] { selections.filter { $0.selected != nil } }
    public var targetCount: Int {
        selected.reduce(0) { $0 + $1.targetURLs.count } + (donSelection?.targetURLs.count ?? 0)
    }
}

public struct IndexedArtwork: Codable, Hashable, Sendable {
    public let relativePath: String
    public let cardID: String?
    public let isDon: Bool
    public let fileSize: Int64
    public let modificationDate: Date
    public let sha256: String
}

public struct CollectionIndex: Codable, Sendable {
    public static let currentVersion = 2
    public let version: Int
    public let sourceFolderPath: String
    public let artworks: [IndexedArtwork]
    public let simulatorAppPath: String
    public let targetRelativePaths: [String: [String]]

    public init(sourceFolderPath: String, artworks: [IndexedArtwork], simulatorAppPath: String, targetRelativePaths: [String: [String]]) {
        self.version = Self.currentVersion
        self.sourceFolderPath = sourceFolderPath
        self.artworks = artworks
        self.simulatorAppPath = simulatorAppPath
        self.targetRelativePaths = targetRelativePaths
    }
}

public final class CollectionIndexStore: @unchecked Sendable {
    private let url: URL

    public init(root: URL) { url = root.appendingPathComponent("collection-index.json") }

    public func load(sourceFolderPath: String) -> CollectionIndex? {
        guard let data = try? Data(contentsOf: url),
              let index = try? JSONDecoder().decode(CollectionIndex.self, from: data),
              index.version == CollectionIndex.currentVersion,
              index.sourceFolderPath == sourceFolderPath else { return nil }
        return index
    }

    public func save(_ index: CollectionIndex) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(index).write(to: url, options: .atomic)
    }
}

public struct ScanMetrics: Sendable {
    public let filesVisited: Int
    public let filesHashed: Int
    public let bytesHashed: Int64
}

public struct ScanOutcome: Sendable {
    public let result: ScanResult
    public let metrics: ScanMetrics
}

public enum AssetScanner {
    public static func scan(settings: UserSettings) throws -> ScanResult {
        try scan(settings: settings, priorIndex: nil).result
    }

    public static func cached(settings: UserSettings, indexStore: CollectionIndexStore) throws -> ScanResult? {
        guard let index = indexStore.load(sourceFolderPath: settings.sourceFolderPath),
              index.simulatorAppPath == settings.simulatorAppPath else { return nil }
        let cardsRoot = cardsRoot(for: URL(fileURLWithPath: settings.simulatorAppPath, isDirectory: true))
        let targets = Dictionary(uniqueKeysWithValues: index.targetRelativePaths.compactMap { rawID, paths in
            CardID(rawValue: rawID).map { ($0, paths.map { cardsRoot.appendingPathComponent($0) }) }
        })
        return try result(settings: settings, artworks: index.artworks, targetsByCard: targets)
    }

    public static func reconcile(settings: UserSettings, indexStore: CollectionIndexStore) throws -> ScanOutcome {
        let prior = indexStore.load(sourceFolderPath: settings.sourceFolderPath)
        let outcome = try scan(settings: settings, priorIndex: prior)
        let cardsRoot = cardsRoot(for: URL(fileURLWithPath: settings.simulatorAppPath, isDirectory: true))
        let canonicalRoot = cardsRoot.resolvingSymlinksInPath().path + "/"
        let targetPaths = Dictionary(uniqueKeysWithValues: outcome.result.selections.map { selection in
            (selection.id, selection.targetURLs.map { $0.resolvingSymlinksInPath().path.replacingOccurrences(of: canonicalRoot, with: "") })
        })
        try indexStore.save(CollectionIndex(sourceFolderPath: settings.sourceFolderPath, artworks: outcome.artworks, simulatorAppPath: settings.simulatorAppPath, targetRelativePaths: targetPaths))
        return ScanOutcome(result: outcome.result, metrics: outcome.metrics)
    }

    private static func scan(settings: UserSettings, priorIndex: CollectionIndex?) throws -> (result: ScanResult, metrics: ScanMetrics, artworks: [IndexedArtwork]) {
        let sourceFolder = URL(fileURLWithPath: settings.sourceFolderPath, isDirectory: true)
        let canonicalSourcePath = sourceFolder.resolvingSymlinksInPath().path
        let simulatorApp = URL(fileURLWithPath: settings.simulatorAppPath, isDirectory: true)
        let cardsRoot = cardsRoot(for: simulatorApp)
        guard FileManager.default.fileExists(atPath: sourceFolder.path) else { throw AltArtError.invalidSource(sourceFolder) }
        guard FileManager.default.fileExists(atPath: cardsRoot.path) else { throw AltArtError.invalidSimulator(simulatorApp) }

        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(at: sourceFolder, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else {
            let empty = ScanResult(sourceFolder: sourceFolder, simulatorApp: simulatorApp, selections: [], donSelection: nil, ignoredFiles: [])
            return (empty, ScanMetrics(filesVisited: 0, filesHashed: 0, bytesHashed: 0), [])
        }

        let priorByPath = Dictionary((priorIndex?.artworks ?? []).map { ($0.relativePath, $0) }, uniquingKeysWith: { _, newest in newest })
        var artworks: [IndexedArtwork] = []
        var ignored: [URL] = []
        var filesVisited = 0
        var filesHashed = 0
        var bytesHashed: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            filesVisited += 1
            let name = url.lastPathComponent
            guard !url.deletingPathExtension().lastPathComponent.lowercased().hasSuffix("_small") else { continue }
            let relative = url.resolvingSymlinksInPath().path.replacingOccurrences(of: canonicalSourcePath + "/", with: "")
            let isDon = isDonArtwork(relativePath: relative, filename: name)
            let cardID = CardID(name)
            guard isDon || cardID != nil else {
                if ["png", "jpg", "jpeg"].contains(url.pathExtension.lowercased()) && name.contains("(") { ignored.append(url) }
                continue
            }
            let fileSize = Int64(values.fileSize ?? 0)
            let modificationDate = values.contentModificationDate ?? .distantPast
            let hash: String
            if let prior = priorByPath[relative], prior.fileSize == fileSize, prior.modificationDate == modificationDate {
                hash = prior.sha256
            } else {
                hash = try sha256(of: url)
                filesHashed += 1
                bytesHashed += fileSize
            }
            artworks.append(IndexedArtwork(relativePath: relative, cardID: cardID?.rawValue, isDon: isDon, fileSize: fileSize, modificationDate: modificationDate, sha256: hash))
        }

        let result = try result(settings: settings, artworks: artworks, ignoredFiles: ignored)
        return (result, ScanMetrics(filesVisited: filesVisited, filesHashed: filesHashed, bytesHashed: bytesHashed), artworks)
    }

    private static func result(settings: UserSettings, artworks: [IndexedArtwork], ignoredFiles: [URL] = [], targetsByCard suppliedTargets: [CardID: [URL]]? = nil) throws -> ScanResult {
        let sourceFolder = URL(fileURLWithPath: settings.sourceFolderPath, isDirectory: true)
        let simulatorApp = URL(fileURLWithPath: settings.simulatorAppPath, isDirectory: true)
        let cardsRoot = cardsRoot(for: simulatorApp)
        guard FileManager.default.fileExists(atPath: sourceFolder.path) else { throw AltArtError.invalidSource(sourceFolder) }
        guard FileManager.default.fileExists(atPath: cardsRoot.path) else { throw AltArtError.invalidSimulator(simulatorApp) }
        var candidatesByCard: [CardID: [AltCandidate]] = [:]
        var donCandidates: [DonCandidate] = []
        for artwork in artworks {
            let url = sourceFolder.appendingPathComponent(artwork.relativePath)
            if artwork.isDon {
                donCandidates.append(DonCandidate(url: url, relativePath: artwork.relativePath, sha256: artwork.sha256))
            } else if let raw = artwork.cardID, let cardID = CardID(rawValue: raw) {
                candidatesByCard[cardID, default: []].append(AltCandidate(cardID: cardID, url: url, relativePath: artwork.relativePath, sha256: artwork.sha256))
            }
        }

        let targetsByCard = suppliedTargets ?? simulatorTargets(cardsRoot: cardsRoot)

        let selections = candidatesByCard.keys.sorted().map { cardID -> CardSelection in
            let candidates = candidatesByCard[cardID, default: []].sorted {
                $0.rarity == $1.rarity
                    ? $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
                    : $0.rarity < $1.rarity
            }
            let targets = targetsByCard[cardID, default: []]
            let saved = settings.choices[cardID.rawValue]
            if let saved {
                if let candidate = candidates.first(where: { $0.relativePath == saved.relativeSourcePath }) {
                    return CardSelection(cardID: cardID, candidates: candidates, targetURLs: targets, selected: candidate, origin: .saved)
                }
                // Never replace an established preference just because its
                // source file disappeared or was moved. New card IDs use the
                // automatic rarity rule below; existing cards instead remain
                // unresolved until the user deliberately picks a replacement.
                return CardSelection(cardID: cardID, candidates: candidates, targetURLs: targets, selected: nil, origin: .stale)
            }
            // New cards are resolved immediately by the product-wide rarity
            // policy. The user can still override any choice in the library.
            let selected = BulkChoiceRule.highestRarity.candidate(from: candidates)
            return CardSelection(cardID: cardID, candidates: candidates, targetURLs: targets, selected: selected, origin: .automatic)
        }
        let sortedDonCandidates = donCandidates.sorted {
            $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
        let donSelection: DonSelection?
        if let firstCandidate = sortedDonCandidates.first {
            let selected = settings.donChoice.flatMap { saved in
                sortedDonCandidates.first(where: { $0.relativePath == saved.relativeSourcePath })
            } ?? firstCandidate
            let origin: DonSelection.Origin = settings.donChoice?.relativeSourcePath == selected.relativePath ? .saved : .automatic
            donSelection = DonSelection(candidates: sortedDonCandidates, targetURLs: donTargetURLs(cardsRoot: cardsRoot), selected: selected, origin: origin)
        } else {
            donSelection = nil
        }
        return ScanResult(sourceFolder: sourceFolder, simulatorApp: simulatorApp, selections: selections, donSelection: donSelection, ignoredFiles: ignoredFiles)
    }

    public static func cardsRoot(for simulatorApp: URL) -> URL {
        simulatorApp.appendingPathComponent("Contents/Resources/Data/StreamingAssets/Cards", isDirectory: true)
    }

    private static func simulatorTargets(cardsRoot: URL) -> [CardID: [URL]] {
        guard let enumerator = FileManager.default.enumerator(at: cardsRoot, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [:] }
        var targets: [CardID: [URL]] = [:]
        for case let url as URL in enumerator {
            let stem = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_small", with: "")
            guard ["png", "jpg", "jpeg"].contains(url.pathExtension.lowercased()), let cardID = CardID(rawValue: stem) else { continue }
            targets[cardID, default: []].append(url)
        }
        return targets
    }

    private static func isDonArtwork(relativePath: String, filename: String) -> Bool {
        let isInDonFolder = relativePath.split(separator: "/").contains { String($0).lowercased().hasPrefix("don") }
        return isInDonFolder || filename.localizedCaseInsensitiveContains("_DON_")
    }

    private static func donTargetURLs(cardsRoot: URL) -> [URL] {
        [
            cardsRoot.appendingPathComponent("Don/Don.png"),
            cardsRoot.appendingPathComponent("P/Don.png"),
            cardsRoot.appendingPathComponent("P/Don_small.jpg")
        ].filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}

public final class SettingsStore: @unchecked Sendable {
    public let root: URL
    private let settingsURL: URL

    public init(root: URL? = nil) {
        let base = root ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/OPTCGAltArtSwitcher", isDirectory: true)
        self.root = base
        self.settingsURL = base.appendingPathComponent("settings.json")
    }

    public func load() -> UserSettings {
        guard let data = try? Data(contentsOf: settingsURL), let saved = try? JSONDecoder().decode(UserSettings.self, from: data) else { return .default }
        return saved
    }

    public func save(_ settings: UserSettings) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = try JSONEncoder.pretty.encode(settings)
        try data.write(to: settingsURL, options: .atomic)
    }
}

public struct ReplacementRecord: Codable, Sendable {
    public let targetRelativePath: String
    public let backupRelativePath: String
    public let originalSHA256: String
    public let outputSHA256: String
    public let sourceSHA256: String?
}

public struct ApplyManifest: Codable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let simulatorAppPath: String
    public let records: [ReplacementRecord]
}

public struct ApplyReport: Sendable {
    public let cardsApplied: Int
    public let donApplied: Bool
    public let filesApplied: Int
    public let backupManifest: URL?
    public let appliedCardIDs: Set<String>
}

public struct ApplyRequest: Sendable {
    public let cardIDs: Set<String>?
    public let includeDon: Bool
    public let onlyChanged: Bool

    public init(cardIDs: Set<String>? = nil, includeDon: Bool = true, onlyChanged: Bool = false) {
        self.cardIDs = cardIDs
        self.includeDon = includeDon
        self.onlyChanged = onlyChanged
    }
}

public final class AssetInstaller: @unchecked Sendable {
    private let store: SettingsStore
    private let fm = FileManager.default

    public init(store: SettingsStore) { self.store = store }

    public func apply(scan: ScanResult, request: ApplyRequest = ApplyRequest()) throws -> ApplyReport {
        let blockingUnresolved = scan.unresolved.filter { request.cardIDs?.contains($0.id) ?? true }
        guard blockingUnresolved.isEmpty else { throw AltArtError.unresolvedChoices(blockingUnresolved.count) }
        guard !isSimulatorRunning(appURL: scan.simulatorApp) else { throw AltArtError.simulatorIsRunning }
        let cardsRoot = AssetScanner.cardsRoot(for: scan.simulatorApp)
        let canonicalCardsRoot = cardsRoot.resolvingSymlinksInPath().path
        let manifestsDirectory = store.root.appendingPathComponent("manifests", isDirectory: true)
        let filesDirectory = store.root.appendingPathComponent("backups/files", isDirectory: true)
        try fm.createDirectory(at: manifestsDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: filesDirectory, withIntermediateDirectories: true)

        var records: [ReplacementRecord] = []
        var filesApplied = 0
        var appliedCardIDs: Set<String> = []
        var donApplied = false
        let knownManifests = try manifests(for: scan.simulatorApp.path)
        let priorRecords = request.onlyChanged ? latestRecordsByTarget(in: knownManifests) : [:]
        for selection in scan.selected {
            guard let candidate = selection.selected else { continue }
            guard request.cardIDs?.contains(selection.id) ?? true else { continue }
            for target in selection.targetURLs {
                let targetRelative = target.resolvingSymlinksInPath().path.replacingOccurrences(of: canonicalCardsRoot + "/", with: "")
                let currentHash = try sha256(of: target)
                if let prior = priorRecords[targetRelative], prior.sourceSHA256 == candidate.sha256, prior.outputSHA256 == currentHash {
                    continue
                }
                let backupRelative = backupPath(for: targetRelative, currentHash: currentHash, filesDirectory: filesDirectory, knownManifests: knownManifests)
                let backupURL = store.root.appendingPathComponent(backupRelative)
                if !fm.fileExists(atPath: backupURL.path) {
                    try fm.createDirectory(at: backupURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.copyItem(at: target, to: backupURL)
                }
                try ImageTranscoder.render(source: candidate.url, template: target)
                let outputHash = try sha256(of: target)
                records.append(ReplacementRecord(targetRelativePath: targetRelative, backupRelativePath: backupRelative, originalSHA256: currentHash, outputSHA256: outputHash, sourceSHA256: candidate.sha256))
                filesApplied += 1
                appliedCardIDs.insert(selection.id)
            }
        }
        if request.includeDon, let donSelection = scan.donSelection {
            for target in donSelection.targetURLs {
                let targetRelative = target.resolvingSymlinksInPath().path.replacingOccurrences(of: canonicalCardsRoot + "/", with: "")
                let currentHash = try sha256(of: target)
                if let prior = priorRecords[targetRelative], prior.sourceSHA256 == donSelection.selected.sha256, prior.outputSHA256 == currentHash {
                    continue
                }
                let backupRelative = backupPath(for: targetRelative, currentHash: currentHash, filesDirectory: filesDirectory, knownManifests: knownManifests)
                let backupURL = store.root.appendingPathComponent(backupRelative)
                if !fm.fileExists(atPath: backupURL.path) {
                    try fm.createDirectory(at: backupURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.copyItem(at: target, to: backupURL)
                }
                try ImageTranscoder.render(source: donSelection.selected.url, template: target)
                let outputHash = try sha256(of: target)
                records.append(ReplacementRecord(targetRelativePath: targetRelative, backupRelativePath: backupRelative, originalSHA256: currentHash, outputSHA256: outputHash, sourceSHA256: donSelection.selected.sha256))
                filesApplied += 1
                donApplied = true
            }
        }
        var manifestURL: URL?
        if !records.isEmpty {
            let manifest = ApplyManifest(id: UUID(), createdAt: Date(), simulatorAppPath: scan.simulatorApp.path, records: records)
            let url = manifestsDirectory.appendingPathComponent("\(manifest.id.uuidString).json")
            try JSONEncoder.pretty.encode(manifest).write(to: url, options: .atomic)
            manifestURL = url
        }
        return ApplyReport(cardsApplied: appliedCardIDs.count, donApplied: donApplied, filesApplied: filesApplied, backupManifest: manifestURL, appliedCardIDs: appliedCardIDs)
    }

    public func restore(simulatorApp: URL) throws -> Int {
        guard !isSimulatorRunning(appURL: simulatorApp) else { throw AltArtError.simulatorIsRunning }
        let currentRecords = latestRecordsByTarget(in: try manifests(for: simulatorApp.path))
        guard !currentRecords.isEmpty else { throw AltArtError.noRestoreAvailable }
        let cardsRoot = AssetScanner.cardsRoot(for: simulatorApp)
        for record in currentRecords.values {
            let target = cardsRoot.appendingPathComponent(record.targetRelativePath)
            guard fm.fileExists(atPath: target.path), try sha256(of: target) == record.outputSHA256 else { throw AltArtError.changedInstallation }
        }
        for record in currentRecords.values {
            let target = cardsRoot.appendingPathComponent(record.targetRelativePath)
            let backup = store.root.appendingPathComponent(record.backupRelativePath)
            guard fm.fileExists(atPath: backup.path) else { throw AltArtError.noRestoreAvailable }
            try atomicReplace(target: target, with: backup)
        }
        return currentRecords.count
    }

    private func backupPath(for targetRelative: String, currentHash: String, filesDirectory: URL, knownManifests: [ApplyManifest]) -> String {
        if let existing = originalBackupForKnownOutput(targetRelative: targetRelative, currentHash: currentHash, manifests: knownManifests) {
            return existing
        }
        let safeTarget = targetRelative.replacingOccurrences(of: "/", with: "__")
        return "backups/files/\(currentHash)-\(safeTarget)"
    }

    private func originalBackupForKnownOutput(targetRelative: String, currentHash: String, manifests: [ApplyManifest]) -> String? {
        for manifest in manifests.sorted(by: { $0.createdAt > $1.createdAt }) {
            if let record = manifest.records.first(where: { $0.targetRelativePath == targetRelative && $0.outputSHA256 == currentHash }) {
                return record.backupRelativePath
            }
        }
        return nil
    }

    private func latestManifest(for simulatorPath: String) throws -> ApplyManifest? {
        try manifests(for: simulatorPath).max(by: { $0.createdAt < $1.createdAt })
    }

    private func latestRecordsByTarget(in manifests: [ApplyManifest]) -> [String: ReplacementRecord] {
        var result: [String: ReplacementRecord] = [:]
        for manifest in manifests.sorted(by: { $0.createdAt < $1.createdAt }) {
            for record in manifest.records { result[record.targetRelativePath] = record }
        }
        return result
    }

    private func manifests(for simulatorPath: String) throws -> [ApplyManifest] {
        let directory = store.root.appendingPathComponent("manifests", isDirectory: true)
        guard let urls = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter({ $0.pathExtension == "json" }) else { return [] }
        return urls.compactMap { url in
            guard let data = try? Data(contentsOf: url), let manifest = try? JSONDecoder.iso8601.decode(ApplyManifest.self, from: data), manifest.simulatorAppPath == simulatorPath else { return nil }
            return manifest
        }
    }
}

public enum ImageTranscoder {
    public static func render(source: URL, template target: URL) throws {
        guard let sourceRef = CGImageSourceCreateWithURL(source as CFURL, nil),
              let sourceImage = CGImageSourceCreateImageAtIndex(sourceRef, 0, nil),
              let targetRef = CGImageSourceCreateWithURL(target as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(targetRef, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { throw AltArtError.unsupportedImage(source) }

        let isJPEG = ["jpg", "jpeg"].contains(target.pathExtension.lowercased())
        let alpha = isJPEG ? CGImageAlphaInfo.noneSkipLast : CGImageAlphaInfo.premultipliedLast
        let bitmapInfo = CGBitmapInfo(rawValue: alpha.rawValue).union(.byteOrder32Big)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmapInfo.rawValue) else { throw AltArtError.unsupportedImage(source) }
        context.interpolationQuality = .high
        context.draw(sourceImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let output = context.makeImage() else { throw AltArtError.unsupportedImage(source) }

        let temporary = target.deletingLastPathComponent().appendingPathComponent(".alt-art-\(UUID().uuidString).tmp")
        let type = isJPEG ? UTType.jpeg.identifier as CFString : UTType.png.identifier as CFString
        guard let destination = CGImageDestinationCreateWithURL(temporary as CFURL, type, 1, nil) else { throw AltArtError.unsupportedImage(source) }
        let options: [CFString: Any] = isJPEG ? [kCGImageDestinationLossyCompressionQuality: 0.92] : [:]
        CGImageDestinationAddImage(destination, output, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw AltArtError.unsupportedImage(source) }
        try atomicReplace(target: target, with: temporary)
    }
}

public func sha256(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while true {
        let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
        guard !data.isEmpty else { break }
        hasher.update(data: data)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

public func atomicReplace(target: URL, with replacement: URL) throws {
    let fm = FileManager.default
    let staging = target.deletingLastPathComponent().appendingPathComponent(".alt-art-staging-\(UUID().uuidString)")
    try fm.copyItem(at: replacement, to: staging)
    _ = try fm.replaceItemAt(target, withItemAt: staging, backupItemName: nil, options: [])
    if fm.fileExists(atPath: replacement.path) { try? fm.removeItem(at: replacement) }
}

public func isSimulatorRunning(appURL: URL) -> Bool {
    let identifier = Bundle(url: appURL)?.bundleIdentifier
    return NSWorkspace.shared.runningApplications.contains { application in
        (identifier != nil && application.bundleIdentifier == identifier) || application.bundleURL?.standardizedFileURL == appURL.standardizedFileURL
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
