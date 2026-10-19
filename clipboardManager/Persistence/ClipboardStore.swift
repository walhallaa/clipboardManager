//
//  ClipboardStore.swift
//  clipboardManager
//
//  All reads and writes to clipboard history and folders. List queries use
//  dictionary fetches restricted to light columns, so the panel never loads a blob.
//

import AppKit
import CoreData
import CryptoKit
import Foundation
import OSLog
import UniformTypeIdentifiers

struct ItemQuery: Sendable, Equatable {
    var search: String = ""
    var kinds: [ClipboardKind]?
    var scope: HistoryScope = .history
    var limit: Int?
}

enum IngestResult: Sendable, Equatable {
    case inserted(ClipboardItem)
    case touched(UUID)
    case ignored
}

struct IngestOptions: Sendable, Equatable {
    var ignoreConcealed = true
    var recordSensitive = true
}

enum FolderDeletion: Sendable, Equatable {
    case moveItemsToHistory
    case deleteItems
}

final class ClipboardStore: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.walhallaa.clipboardManager", category: "ClipboardStore")

    private let persistence: PersistenceController
    let blobs: BlobStore
    private var context: NSManagedObjectContext { persistence.context }

    init(persistence: PersistenceController, blobs: BlobStore) {
        self.persistence = persistence
        self.blobs = blobs
    }

    // MARK: - Lifecycle

    /// Opens the store, upgrades v2.x rows and sweeps orphaned files.
    func prepare() async throws {
        try await persistence.ready()
        try await context.perform { [self] in
            try migrateLegacyRows()
        }
        await sweepOrphans()
    }

    // MARK: - Queries

    private static let listProperties = [
        "id", "type", "timestamp", "isPinned", "previewText", "contentDescriptionString",
        "sourceAppName", "sourceBundleID", "byteCount", "fileName", "fileURL", "bookmark",
        "imagePath", "thumbnailPath", "pixelWidth", "pixelHeight", "contentHash",
        "folderID", "sensitivity", "linkTitle", "linkIconPath",
    ]

    static func searchTerms(_ search: String) -> [String] {
        search.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    func load(_ query: ItemQuery) async throws -> [ClipboardItem] {
        try await persistence.ready()
        return try await context.perform { [self] in
            let request = NSFetchRequest<NSDictionary>(entityName: "ClipboardEntity")
            request.resultType = .dictionaryResultType
            request.propertiesToFetch = Self.listProperties
            request.sortDescriptors = [
                NSSortDescriptor(key: "isPinned", ascending: false),
                NSSortDescriptor(key: "timestamp", ascending: false),
            ]
            var predicates: [NSPredicate] = []
            let terms = Self.searchTerms(query.search)
            switch query.scope {
            case .history:
                // Searching from History looks inside folders too; browsing doesn't.
                if terms.isEmpty { predicates.append(NSPredicate(format: "folderID == nil")) }
            case let .folder(id):
                predicates.append(NSPredicate(format: "folderID == %@", id as CVarArg))
            }
            // Every word must appear somewhere, in any order: "phd karolinska"
            // finds an email that mentions both.
            for term in terms {
                predicates.append(NSPredicate(
                    format: "previewText CONTAINS[cd] %@ OR text CONTAINS[cd] %@ OR fileName CONTAINS[cd] %@ OR sourceAppName CONTAINS[cd] %@ OR linkTitle CONTAINS[cd] %@",
                    term, term, term, term, term
                ))
            }
            if let kinds = query.kinds {
                predicates.append(NSPredicate(format: "type IN %@", kinds.map(\.rawValue)))
            }
            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
            if let limit = query.limit { request.fetchLimit = limit }
            return try context.fetch(request).compactMap { ClipboardItem(row: $0) }
        }
    }

    func payload(for id: UUID) async throws -> ClipboardPayload? {
        try await persistence.ready()
        return try await context.perform { [self] in
            guard let entity = try fetchEntity(id: id) else { return nil }
            return payload(from: entity)
        }
    }

    func storageFootprint() async -> Int64 {
        blobs.footprint + persistence.storeFileSize
    }

    // MARK: - Folders

    func folders() async throws -> [ClipboardFolder] {
        try await persistence.ready()
        return try await context.perform { [self] in
            let request: NSFetchRequest<FolderEntity> = FolderEntity.fetchRequest()
            request.sortDescriptors = [
                NSSortDescriptor(key: "sortIndex", ascending: true),
                NSSortDescriptor(key: "createdAt", ascending: true),
            ]
            return try context.fetch(request).compactMap { entity -> ClipboardFolder? in
                guard let id = entity.id else { return nil }
                let count = try? context.count(for: Self.itemsRequest(inFolder: id))
                return ClipboardFolder(
                    id: id,
                    name: entity.name ?? "Untitled",
                    symbol: entity.symbol ?? "folder",
                    createdAt: entity.createdAt ?? .distantPast,
                    itemCount: count ?? 0
                )
            }
        }
    }

    func createFolder(named name: String) async throws -> ClipboardFolder {
        try await persistence.ready()
        return try await context.perform { [self] in
            let existing = try context.count(for: FolderEntity.fetchRequest())
            let entity = FolderEntity(context: context)
            let id = UUID()
            entity.id = id
            entity.name = name
            entity.symbol = "folder"
            entity.createdAt = Date()
            entity.sortIndex = Int32(existing)
            try context.save()
            return ClipboardFolder(id: id, name: name, symbol: "folder", createdAt: entity.createdAt ?? Date(), itemCount: 0)
        }
    }

    func renameFolder(id: UUID, to name: String) async throws {
        try await persistence.ready()
        try await context.perform { [self] in
            guard let entity = try fetchFolder(id: id) else { return }
            entity.name = name
            try context.save()
        }
    }

    func deleteFolder(id: UUID, strategy: FolderDeletion) async throws {
        try await persistence.ready()
        let files: [(String?, String?)] = try await context.perform { [self] in
            let items = try context.fetch(Self.itemsRequest(inFolder: id))
            var files: [(String?, String?)] = []
            switch strategy {
            case .moveItemsToHistory:
                for item in items {
                    item.folderID = nil
                    item.timestamp = Date()
                }
            case .deleteItems:
                files = items.map { ($0.imagePath, $0.thumbnailPath) }
                items.forEach(context.delete)
            }
            if let folder = try fetchFolder(id: id) { context.delete(folder) }
            try context.save()
            return files
        }
        for (image, thumb) in files { blobs.remove(imageName: image, thumbnailName: thumb) }
    }

    func moveItem(id: UUID, toFolder folderID: UUID?) async throws {
        try await persistence.ready()
        try await context.perform { [self] in
            guard let entity = try fetchEntity(id: id) else { return }
            entity.folderID = folderID
            entity.timestamp = Date()
            try context.save()
        }
    }

    // MARK: - Ingest

    func ingest(_ snapshot: PasteboardSnapshot, options: IngestOptions) async throws -> IngestResult {
        try await persistence.ready()

        if let markerID = snapshot.ownMarkerID {
            let touched = try await touch(id: markerID)
            return touched ? .touched(markerID) : .ignored
        }
        if options.ignoreConcealed, snapshot.isConcealed || snapshot.isTransient {
            return .ignored
        }
        guard let draft = Draft(snapshot: snapshot) else { return .ignored }
        if draft.sensitive != nil, !options.recordSensitive { return .ignored }

        if let existing = try await existingID(hash: draft.hash) {
            _ = try await touch(id: existing)
            return .touched(existing)
        }

        let id = UUID()
        let stored: BlobStore.StoredImage?
        if draft.kind == .image, let data = draft.imageData {
            stored = try await Task.detached(priority: .userInitiated) { [blobs] in
                try blobs.storeImage(data, id: id)
            }.value
            guard stored != nil else { return .ignored }
        } else {
            stored = nil
        }

        let item = try await context.perform { [self] in
            let entity = ClipboardEntity(context: context)
            entity.id = id
            entity.timestamp = Date()
            entity.type = draft.kind.rawValue
            entity.isPinned = false
            entity.contentHash = draft.hash
            entity.sourceAppName = draft.source.name
            entity.sourceBundleID = draft.source.bundleID
            entity.previewText = draft.preview
            entity.contentDescriptionString = draft.preview
            entity.text = draft.text
            entity.richTextData = draft.richText
            entity.byteCount = draft.byteCount
            if let sensitive = draft.sensitive {
                entity.sensitivity = Self.encodeSensitivity(sensitive.kind, detail: sensitive.detail)
            }
            if let stored {
                entity.imagePath = stored.imageName
                entity.thumbnailPath = stored.thumbnailName
                entity.pixelWidth = Int32(stored.pixelSize.width)
                entity.pixelHeight = Int32(stored.pixelSize.height)
                entity.byteCount = stored.byteCount
            }
            if let fileURL = draft.fileURL {
                entity.fileURL = fileURL
                entity.fileName = fileURL.lastPathComponent
                entity.bookmark = FileBookmark.make(for: fileURL)
                entity.byteCount = Int64((try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
            try context.save()
            return ClipboardItem(entity: entity)
        }
        return .inserted(item)
    }

    /// Generates a Quick Look thumbnail for a file-backed item. Returns the updated item.
    func generateFileThumbnail(for id: UUID) async throws -> ClipboardItem? {
        try await persistence.ready()
        let source: (bookmark: Data?, url: URL?)? = try await context.perform { [self] in
            guard let entity = try fetchEntity(id: id), entity.thumbnailPath == nil else { return nil }
            return (entity.bookmark, entity.fileURL)
        }
        guard let source else { return nil }

        let resolved = FileBookmark.resolve(source.bookmark ?? Data())
        let url = resolved?.url ?? source.url
        guard let url else { return nil }
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        guard let name = await blobs.storeFileThumbnail(for: url, id: id) else { return nil }

        return try await context.perform { [self] in
            guard let entity = try fetchEntity(id: id) else { return nil }
            entity.thumbnailPath = name
            try context.save()
            return ClipboardItem(entity: entity)
        }
    }

    /// Stores a fetched title plus optional hero image and favicon for a link.
    func setLinkMetadata(_ metadata: LinkMetadata, for id: UUID) async throws -> ClipboardItem? {
        try await persistence.ready()
        let heroName = metadata.imagePNG.flatMap { blobs.writeThumbnail($0, name: "\(id.uuidString).png") }
        let iconName = metadata.iconPNG.flatMap { blobs.writeThumbnail($0, name: "\(id.uuidString)-icon.png") }
        return try await context.perform { [self] in
            guard let entity = try fetchEntity(id: id) else { return nil }
            if let title = metadata.title, !title.isEmpty { entity.linkTitle = title }
            if let heroName { entity.thumbnailPath = heroName }
            if let iconName { entity.linkIconPath = iconName }
            try context.save()
            return ClipboardItem(entity: entity)
        }
    }

    /// Stores text recognised in an image so it becomes searchable and previewable.
    func setRecognizedText(_ text: String, for id: UUID) async throws -> ClipboardItem? {
        try await persistence.ready()
        return try await context.perform { [self] in
            guard let entity = try fetchEntity(id: id) else { return nil }
            entity.text = text
            let excerpt = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }.joined(separator: " ")
            entity.previewText = String(excerpt.prefix(160))
            try context.save()
            return ClipboardItem(entity: entity)
        }
    }

    // MARK: - Mutations

    @discardableResult
    func touch(id: UUID) async throws -> Bool {
        try await persistence.ready()
        return try await context.perform { [self] in
            guard let entity = try fetchEntity(id: id) else { return false }
            entity.timestamp = Date()
            try context.save()
            return true
        }
    }

    func setPinned(id: UUID, _ pinned: Bool) async throws {
        try await persistence.ready()
        try await context.perform { [self] in
            guard let entity = try fetchEntity(id: id) else { return }
            entity.isPinned = pinned
            try context.save()
        }
    }

    /// Masks a text item by hand, or clears any sensitivity (detected or marked).
    /// Returns the updated item so the list can re-render it masked or plain.
    func setSensitive(id: UUID, _ sensitive: Bool) async throws -> ClipboardItem? {
        try await persistence.ready()
        return try await context.perform { [self] in
            guard let entity = try fetchEntity(id: id), let text = entity.text else { return nil }
            if sensitive {
                let match = SensitiveContent.markedByUser(text)
                entity.sensitivity = Self.encodeSensitivity(match.kind, detail: nil)
                entity.previewText = match.masked
            } else {
                entity.sensitivity = nil
                entity.previewText = TextClassifier.preview(for: text)
            }
            try context.save()
            return ClipboardItem(entity: entity)
        }
    }

    func delete(ids: [UUID]) async throws {
        try await persistence.ready()
        let files = try await context.perform { [self] in
            let request: NSFetchRequest<ClipboardEntity> = ClipboardEntity.fetchRequest()
            request.predicate = NSPredicate(format: "id IN %@", ids)
            let entities = try context.fetch(request)
            let files = entities.map { ($0.imagePath, $0.thumbnailPath, $0.linkIconPath) }
            entities.forEach(context.delete)
            try context.save()
            return files
        }
        for (image, thumb, icon) in files {
            blobs.remove(imageName: image, thumbnailName: thumb)
            blobs.remove(imageName: nil, thumbnailName: icon)
        }
    }

    func deleteAll() async throws {
        try await persistence.ready()
        try await context.perform { [self] in
            for entityName in ["ClipboardEntity", "FolderEntity"] {
                let request = NSFetchRequest<NSFetchRequestResult>(entityName: entityName)
                let batch = NSBatchDeleteRequest(fetchRequest: request)
                batch.resultType = .resultTypeObjectIDs
                let result = try context.execute(batch) as? NSBatchDeleteResult
                let ids = (result?.result as? [NSManagedObjectID]) ?? []
                NSManagedObjectContext.mergeChanges(fromRemoteContextSave: [NSDeletedObjectsKey: ids], into: [context])
            }
        }
        blobs.removeAll()
    }

    /// Applies retention to unpinned history items (folders are exempt) and returns the removed ids.
    func prune(_ policy: RetentionPolicy) async throws -> [UUID] {
        try await persistence.ready()
        let victims: [(UUID, String?, String?)] = try await context.perform { [self] in
            let request: NSFetchRequest<ClipboardEntity> = ClipboardEntity.fetchRequest()
            request.predicate = NSPredicate(format: "isPinned == NO AND folderID == nil")
            request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
            let unpinned = try context.fetch(request)
            var doomed: Set<ClipboardEntity> = []
            if let maxCount = policy.maxCount, unpinned.count > maxCount {
                doomed.formUnion(unpinned[maxCount...])
            }
            if let maxAge = policy.maxAge {
                let cutoff = Date().addingTimeInterval(-maxAge)
                doomed.formUnion(unpinned.filter { ($0.timestamp ?? .distantPast) < cutoff })
            }
            if let sensitiveMaxAge = policy.sensitiveMaxAge {
                let cutoff = Date().addingTimeInterval(-sensitiveMaxAge)
                doomed.formUnion(unpinned.filter { $0.sensitivity != nil && ($0.timestamp ?? .distantPast) < cutoff })
            }
            guard !doomed.isEmpty else { return [] }
            let records = doomed.compactMap { entity -> (UUID, String?, String?)? in
                guard let id = entity.id else { return nil }
                return (id, entity.imagePath, entity.thumbnailPath)
            }
            doomed.forEach(context.delete)
            try context.save()
            return records
        }
        for (_, image, thumb) in victims { blobs.remove(imageName: image, thumbnailName: thumb) }
        return victims.map(\.0)
    }

    // MARK: - Private helpers

    private static func itemsRequest(inFolder id: UUID) -> NSFetchRequest<ClipboardEntity> {
        let request: NSFetchRequest<ClipboardEntity> = ClipboardEntity.fetchRequest()
        request.predicate = NSPredicate(format: "folderID == %@", id as CVarArg)
        return request
    }

    private func fetchEntity(id: UUID) throws -> ClipboardEntity? {
        let request: NSFetchRequest<ClipboardEntity> = ClipboardEntity.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        return try context.fetch(request).first
    }

    private func fetchFolder(id: UUID) throws -> FolderEntity? {
        let request: NSFetchRequest<FolderEntity> = FolderEntity.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        return try context.fetch(request).first
    }

    /// Duplicate detection only considers the history timeline; folders keep their own copies.
    private func existingID(hash: String) async throws -> UUID? {
        try await context.perform { [self] in
            let request = NSFetchRequest<NSDictionary>(entityName: "ClipboardEntity")
            request.resultType = .dictionaryResultType
            request.propertiesToFetch = ["id"]
            request.predicate = NSPredicate(format: "contentHash == %@ AND folderID == nil", hash)
            request.fetchLimit = 1
            return try context.fetch(request).first?["id"] as? UUID
        }
    }

    private func payload(from entity: ClipboardEntity) -> ClipboardPayload {
        let kind = ClipboardKind(rawValue: entity.type ?? "") ?? .text
        var payload = ClipboardPayload(kind: kind)
        payload.text = entity.text ?? entity.content.flatMap { String(data: $0, encoding: .utf8) }
        payload.richText = entity.richTextData
        payload.fileName = entity.fileName
        if let imagePath = entity.imagePath {
            payload.imageFileURL = blobs.imageURL(for: imagePath)
        } else if kind == .image, let legacy = entity.fileURL {
            payload.imageFileURL = legacy
        }
        if kind.isFileBacked {
            payload.bookmark = entity.bookmark
            payload.fileURL = entity.bookmark.flatMap { FileBookmark.resolve($0)?.url } ?? entity.fileURL
        }
        return payload
    }

    static func encodeSensitivity(_ kind: SensitiveKind, detail: String?) -> String {
        detail.map { "\(kind.rawValue)|\($0)" } ?? kind.rawValue
    }

    static func decodeSensitivity(_ raw: String?) -> (SensitiveKind, String?)? {
        guard let raw else { return nil }
        let parts = raw.split(separator: "|", maxSplits: 1).map(String.init)
        guard let first = parts.first, let kind = SensitiveKind(rawValue: first) else { return nil }
        return (kind, parts.count > 1 ? parts[1] : nil)
    }

    /// Fills in v2 columns for rows written by older versions, removing rows whose
    /// temporary files were lost (v2.x wrote images to the tmp directory).
    private func migrateLegacyRows() throws {
        let request: NSFetchRequest<ClipboardEntity> = ClipboardEntity.fetchRequest()
        request.predicate = NSPredicate(format: "contentHash == nil")
        let legacy = try context.fetch(request)
        guard !legacy.isEmpty else { return }
        Self.logger.notice("Upgrading \(legacy.count) legacy rows")

        for entity in legacy {
            let kind = ClipboardKind(rawValue: entity.type ?? "") ?? .text
            switch kind {
            case .text, .url, .color:
                let text = entity.content.flatMap { String(data: $0, encoding: .utf8) } ?? entity.contentDescriptionString ?? ""
                let detected = TextClassifier.kind(for: text)
                entity.type = detected.rawValue
                entity.text = text
                if detected == .text, let sensitive = SensitiveContent.detect(in: text) {
                    entity.previewText = sensitive.masked
                    entity.sensitivity = Self.encodeSensitivity(sensitive.kind, detail: sensitive.detail)
                } else {
                    entity.previewText = detected == .color ? (ParsedColor.parse(text)?.hexString ?? text) : TextClassifier.preview(for: text)
                }
                entity.contentHash = Draft.hash(of: Data(text.utf8), kind: detected)
                entity.byteCount = Int64(text.utf8.count)
            case .image, .file, .video:
                let reachable = entity.fileURL.map { (try? $0.checkResourceIsReachable()) ?? false } ?? false
                guard reachable, let url = entity.fileURL else {
                    context.delete(entity)
                    continue
                }
                entity.fileName = url.lastPathComponent
                entity.previewText = url.lastPathComponent
                entity.contentHash = Draft.hash(of: Data(url.path.utf8), kind: kind)
                entity.bookmark = FileBookmark.make(for: url)
            }
            if let legacyApp = entity.copiedFromApplication,
               let decoded = try? JSONDecoder().decode(LegacySourceApp.self, from: legacyApp) {
                entity.sourceAppName = decoded.applicationTitle ?? "Unknown"
            }
            entity.content = nil
            entity.pasteboardItemsData = nil
            entity.copiedFromApplication = nil
        }
        try context.save()
    }

    private func sweepOrphans() async {
        let referenced: (Set<String>, Set<String>)? = try? await context.perform { [self] in
            let request = NSFetchRequest<NSDictionary>(entityName: "ClipboardEntity")
            request.resultType = .dictionaryResultType
            request.propertiesToFetch = ["imagePath", "thumbnailPath", "linkIconPath"]
            let rows = try context.fetch(request)
            return (
                Set(rows.compactMap { $0["imagePath"] as? String }),
                Set(rows.compactMap { $0["thumbnailPath"] as? String } + rows.compactMap { $0["linkIconPath"] as? String })
            )
        }
        guard let referenced else { return }
        blobs.removeOrphans(keepingImages: referenced.0, thumbnails: referenced.1)
    }
}

private struct LegacySourceApp: Decodable {
    var applicationTitle: String?
}

// MARK: - Draft (classification of a snapshot)

private struct Draft {
    var kind: ClipboardKind
    var text: String?
    var richText: Data?
    var preview: String
    var imageData: Data?
    var fileURL: URL?
    var source: SourceApp
    var hash: String
    var byteCount: Int64
    var sensitive: SensitiveMatch?

    init?(snapshot: PasteboardSnapshot) {
        source = snapshot.source

        if let url = snapshot.fileURLs.first {
            let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType) ?? .data
            kind = type.conforms(to: .movie) ? .video : .file
            fileURL = url
            preview = url.lastPathComponent
            hash = Self.hash(of: Data(url.path.utf8), kind: kind)
            byteCount = 0
            return
        }

        let string = snapshot.string ?? ""
        let hasText = !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        if hasText {
            let detected = TextClassifier.kind(for: string)
            kind = detected
            text = string
            richText = snapshot.rtf
            switch detected {
            case .color:
                let parsed = ParsedColor.parse(string)
                preview = parsed?.hexString ?? string
            case .url:
                preview = string.trimmingCharacters(in: .whitespacesAndNewlines)
            default:
                if let match = SensitiveContent.detect(in: string) {
                    sensitive = match
                    preview = match.masked
                    richText = nil
                } else {
                    preview = TextClassifier.preview(for: string)
                }
            }
            hash = Self.hash(of: Data(string.utf8), kind: detected)
            byteCount = Int64(string.utf8.count)
            return
        }

        if let data = snapshot.images.first {
            kind = .image
            imageData = data
            preview = ""
            hash = Self.hash(of: data, kind: .image)
            byteCount = Int64(data.count)
            return
        }

        if let hex = snapshot.colorHex {
            kind = .color
            text = hex
            preview = hex
            hash = Self.hash(of: Data(hex.utf8), kind: .color)
            byteCount = Int64(hex.utf8.count)
            return
        }

        return nil
    }

    static func hash(of data: Data, kind: ClipboardKind) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(kind.rawValue.utf8))
        hasher.update(data: data)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Mapping

extension ClipboardItem {
    init?(row: NSDictionary) {
        guard let id = row["id"] as? UUID else { return nil }
        let kind = ClipboardKind(rawValue: row["type"] as? String ?? "") ?? .text
        let bookmark = row["bookmark"] as? Data
        let fileURL = row["fileURL"] as? URL
        let width = row["pixelWidth"] as? Int ?? 0
        let height = row["pixelHeight"] as? Int ?? 0
        let sensitivity = ClipboardStore.decodeSensitivity(row["sensitivity"] as? String)
        self.init(
            id: id,
            kind: kind,
            timestamp: row["timestamp"] as? Date ?? .distantPast,
            isPinned: row["isPinned"] as? Bool ?? false,
            preview: (row["previewText"] as? String) ?? (row["contentDescriptionString"] as? String) ?? "",
            source: SourceApp(name: row["sourceAppName"] as? String ?? "Unknown", bundleID: row["sourceBundleID"] as? String),
            byteCount: Int64(row["byteCount"] as? Int ?? 0),
            fileName: row["fileName"] as? String,
            filePath: fileURL?.path,
            imagePath: row["imagePath"] as? String,
            thumbnailPath: row["thumbnailPath"] as? String,
            pixelSize: width > 0 && height > 0 ? PixelSize(width: width, height: height) : nil,
            contentHash: row["contentHash"] as? String ?? "",
            isFileAvailable: kind.isFileBacked ? FileBookmark.isReachable(bookmark: bookmark, fallbackURL: fileURL) : true,
            folderID: row["folderID"] as? UUID,
            sensitivity: sensitivity?.0,
            sensitivityDetail: sensitivity?.1,
            linkTitle: row["linkTitle"] as? String,
            linkIconPath: row["linkIconPath"] as? String,
            codeLanguage: nil
        )
        if kind == .text, sensitivity == nil {
            codeLanguage = CodeLanguage.detect(preview)
            if codeLanguage == nil { smartActions = SmartDetector.actions(for: preview) }
        }
    }

    init(entity: ClipboardEntity) {
        let kind = ClipboardKind(rawValue: entity.type ?? "") ?? .text
        let sensitivity = ClipboardStore.decodeSensitivity(entity.sensitivity)
        self.init(
            id: entity.id ?? UUID(),
            kind: kind,
            timestamp: entity.timestamp ?? .distantPast,
            isPinned: entity.isPinned,
            preview: entity.previewText ?? entity.contentDescriptionString ?? "",
            source: SourceApp(name: entity.sourceAppName ?? "Unknown", bundleID: entity.sourceBundleID),
            byteCount: entity.byteCount,
            fileName: entity.fileName,
            filePath: entity.fileURL?.path,
            imagePath: entity.imagePath,
            thumbnailPath: entity.thumbnailPath,
            pixelSize: entity.pixelWidth > 0 && entity.pixelHeight > 0
                ? PixelSize(width: Int(entity.pixelWidth), height: Int(entity.pixelHeight)) : nil,
            contentHash: entity.contentHash ?? "",
            isFileAvailable: kind.isFileBacked ? FileBookmark.isReachable(bookmark: entity.bookmark, fallbackURL: entity.fileURL) : true,
            folderID: entity.folderID,
            sensitivity: sensitivity?.0,
            sensitivityDetail: sensitivity?.1,
            linkTitle: entity.linkTitle,
            linkIconPath: entity.linkIconPath,
            codeLanguage: nil
        )
        if kind == .text, sensitivity == nil {
            codeLanguage = CodeLanguage.detect(preview)
            if codeLanguage == nil { smartActions = SmartDetector.actions(for: preview) }
        }
    }
}
