// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Foundation
import Darwin

indirect enum SteamInputKV {
    case text(String)
    case list([(String, SteamInputKV)])

    var string: String? { if case .text(let value) = self { return value }; return nil }
    var entries: [(String, SteamInputKV)] { if case .list(let value) = self { return value }; return [] }
    /// Every value under `key`, case-insensitively.
    func all(_ key: String) -> [SteamInputKV] { entries.filter { $0.0.caseInsensitiveCompare(key) == .orderedSame }.map(\.1) }
    subscript(_ key: String) -> SteamInputKV? { all(key).first }
    func text(_ key: String) -> String? { self[key]?.string }

    static func parse(_ data: Data) throws -> SteamInputKV {
        guard data.count <= (1 << 20) - 1 else { throw SteamFileError.invalid("The layout is too large.") }
        var bytes = Array(data)
        if bytes.starts(with: [0xef, 0xbb, 0xbf]) { bytes.removeFirst(3) }
        var position = 0
        var depth = 0
        var tokens = 0
        guard String(data: data, encoding: .utf8) != nil, !data.contains(0) else { throw SteamFileError.invalid("The layout is not UTF-8 text.") }

        func skipSpaceAndComments() {
            while position < bytes.count {
                let c = bytes[position]
                if c == 0x20 || c == 0x09 || c == 0x0a || c == 0x0d { position += 1; continue }
                if c == 0x2f, position + 1 < bytes.count, bytes[position + 1] == 0x2f {
                    while position < bytes.count, bytes[position] != 0x0a { position += 1 }
                    continue
                }
                break
            }
        }
        /// A quoted or bare token; nil at a brace or the end.
        func token() throws -> String? {
            tokens += 1
            guard tokens <= 100_000 else { throw SteamFileError.invalid("The layout has too many entries.") }
            skipSpaceAndComments()
            guard position < bytes.count else { return nil }
            let c = bytes[position]
            if c == 0x7b || c == 0x7d { return nil }
            var out: [UInt8] = []
            if c == 0x22 {
                position += 1
                while position < bytes.count, bytes[position] != 0x22 {
                    if bytes[position] == 0x5c, position + 1 < bytes.count {
                        let next = bytes[position + 1]
                        switch next {
                        case 0x6e: out.append(0x0a)
                        case 0x74: out.append(0x09)
                        case 0x5c, 0x22: out.append(next)
                        default: out.append(0x5c); out.append(next)
                        }
                        position += 2
                        continue
                    }
                    out.append(bytes[position]); position += 1
                }
                guard position < bytes.count else { throw SteamFileError.invalid("The layout ends inside a string.") }
                position += 1
            } else {
                while position < bytes.count {
                    let b = bytes[position]
                    if b == 0x20 || b == 0x09 || b == 0x0a || b == 0x0d || b == 0x7b || b == 0x7d || b == 0x22 { break }
                    out.append(b); position += 1
                }
            }
            return String(decoding: out, as: UTF8.self)
        }
        /// Reject platform conditions until their selection semantics are supported.
        func skipCondition() throws {
            skipSpaceAndComments()
            guard position < bytes.count, bytes[position] == 0x5b else { return }
            throw SteamFileError.invalid("Conditional layouts are not supported yet.")
        }
        func list(closing: Bool) throws -> SteamInputKV {
            depth += 1
            guard depth < 64 else { throw SteamFileError.invalid("The layout nests too deeply.") }
            defer { depth -= 1 }
            var out: [(String, SteamInputKV)] = []
            while true {
                skipSpaceAndComments()
                guard position < bytes.count else {
                    if closing { throw SteamFileError.invalid("The layout ends inside a block.") }
                    return .list(out)
                }
                if bytes[position] == 0x7d {
                    guard closing else { throw SteamFileError.invalid("The layout has an unmatched }.") }
                    position += 1
                    return .list(out)
                }
                guard let key = try token() else { throw SteamFileError.invalid("The layout has a block without a name.") }
                if key.hasPrefix("#") { throw SteamFileError.invalid("Layouts that include other files are not supported.") }
                skipSpaceAndComments()
                guard position < bytes.count else { throw SteamFileError.invalid("The layout ends after a name.") }
                if bytes[position] == 0x7b {
                    position += 1
                    out.append((key, try list(closing: true)))
                } else {
                    guard let value = try token() else { throw SteamFileError.invalid("The layout has a name without a value.") }
                    out.append((key, .text(value)))
                }
                try skipCondition()
            }
        }
        return try list(closing: false)
    }
}

/// Reads compatibility only. Valve evaluates the untouched bindings, including
/// unknown fields, repeated groups, activators and layers.
struct SteamInputCompatibility: Equatable {
    let controller: String
    let unsupported: [String]
    var canApply: Bool { unsupported.isEmpty }
    var description: String {
        canApply ? "Compatible with Madeira's virtual DualSense. Buttons, sticks and triggers are forwarded."
            : "Unavailable inputs or features: " + unsupported.joined(separator: ", ") + "."
    }
    init(_ bytes: Data, tags: [String] = []) throws {
        let document = try SteamInputKV.parse(bytes)
        let roots = document.all("controller_mappings")
        guard roots.count == 1, case .list = roots[0] else { throw SteamInputCommunitySources.Failure.invalid }
        let mapping = roots[0]
        // A group, action set or layer the layout names but does not define
        // exactly once is refused here, with the reason, before anything below.
        try SteamInputReferences.check(bytes)
        let nativeType = try SteamInputDefaultSources.controllerType(bytes).unwrap()
        let tagged = Set(tags.filter { $0.hasPrefix("controller_") && $0 != "controller_native" })
        guard tagged.count <= 1 else { throw SteamInputCommunitySources.Failure.invalid }
        controller = nativeType.isEmpty ? tagged.first ?? "" : nativeType.lowercased()
        if let tag = tagged.first, !nativeType.isEmpty, tag != controller { throw SteamInputCommunitySources.Failure.invalid }
        var missing = Set<String>()
        if !["controller_ps5", "controller_ps4"].contains(controller) { missing.insert("controller type " + (controller.isEmpty ? "unspecified" : controller)) }
        // Workshop feature tags describe the whole file. The raw bindings below
        // decide which inputs are actually enabled in its presets and layers.
        var groups: [String: SteamInputKV] = [:]
        for group in mapping.all("group") {
            guard let id = group.text("id"), groups[id] == nil else { throw SteamInputCommunitySources.Failure.invalid }
            groups[id] = group
        }
        let forwarded: Set<String> = ["button_diamond", "dpad", "joystick", "right_joystick", "left_trigger", "right_trigger", "switch"]
        for preset in mapping.all("preset") {
            for (id, value) in preset["group_source_bindings"]?.entries ?? [] {
                guard let words = value.string?.lowercased().split(separator: " "), let source = words.first,
                      let group = groups[id] else { throw SteamInputCommunitySources.Failure.invalid }
                if words.dropFirst().contains("inactive") { continue }
                let mode = group.text("mode")?.lowercased() ?? ""
                if mode == "none" || mode == "disabled" { continue }
                if !forwarded.contains(String(source)) { missing.insert(String(source).replacingOccurrences(of: "_", with: " ")) }
                if mode.contains("radial") || mode.contains("touch_menu") { missing.insert("overlay menus") }
                for (input, _) in group["inputs"]?.entries ?? [] {
                    if ["grip", "rear", "paddle"].contains(where: { input.lowercased().contains($0) }) { missing.insert("rear buttons") }
                }
            }
        }
        unsupported = missing.sorted()
    }
}

private extension Optional {
    func unwrap() throws -> Wrapped {
        guard let self else { throw SteamInputCommunitySources.Failure.invalid }; return self
    }
}

/// Public data only; account-specific choices and personal copies live in the
/// existing selection journal and a separate account-scoped personal store.
@MainActor final class SteamInputCommunitySources {
    static let shared = SteamInputCommunitySources()
    private static let session = SteamSession(anonymous: true)
    static let limit = (1 << 20) - 1
    enum Failure: LocalizedError {
        case invalid, unavailable, changed, incompatible, busy
        var errorDescription: String? {
            switch self {
            case .invalid: return "Steam returned an invalid layout or a layout for another game."
            case .unavailable: return "This public layout is unavailable. Your saved layout is kept."
            case .changed: return "The layout changed while downloading. Refresh and try again."
            case .incompatible: return "This layout needs inputs or features Madeira cannot currently forward."
            case .busy: return "This layout is already being downloaded."
            }
        }
    }
    enum Order: UInt32, CaseIterable, Identifiable, Codable {
        case played = 14, popular = 9, recent = 1
        var id: UInt32 { rawValue }
        var label: String { switch self { case .played: return "Most played"; case .popular: return "Most subscribed"; case .recent: return "Most recent" } }
    }
    struct Page: Codable, Equatable {
        var version = 1
        let appID: UInt32
        let order: Order
        let text: String
        let number: UInt32
        let total: Int
        let items: [SteamWorkshopItem]
        let fetched: Date
    }
    struct Revision: Codable, Equatable, Identifiable {
        var version = 1
        let appID: UInt32
        let item: SteamWorkshopItem
        let hash: String
        let downloaded: Date
        var id: String { "\(item.id)-\(hash)" }
        var attribution: String { "\(String(String.UnicodeScalarView(item.title.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(100)))) · Workshop \(item.id)" }
        func matches(_ candidate: SteamWorkshopItem) -> Bool {
            Self.sameContent(item, candidate)
        }
        fileprivate static func sameContent(_ lhs: SteamWorkshopItem, _ rhs: SteamWorkshopItem) -> Bool {
            lhs.id == rhs.id && lhs.timeUpdated == rhs.timeUpdated && lhs.revisionChangeNumber == rhs.revisionChangeNumber &&
                lhs.content == rhs.content && lhs.fileSize == rhs.fileSize && lhs.fileURL == rhs.fileURL &&
                lhs.tags == rhs.tags && lhs.kvTags == rhs.kvTags
        }
    }
    struct Layout {
        let revision: Revision
        let bytes: Data
        let compatibility: SteamInputCompatibility
    }
    typealias Query = (UInt32, Order, String, UInt32) async throws -> SteamWorkshopPage
    typealias Details = ([UInt64]) async throws -> [SteamWorkshopItem]
    typealias Download = (URL) async throws -> Data
    private let root: URL
    private let query: Query
    private let details: Details
    private let download: Download
    private var transfers = Set<String>()

    init(root: URL? = nil, query: Query? = nil, details: Details? = nil, download: Download? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SteamInputCommunity", isDirectory: true)
        self.query = query ?? Self.fetchPage
        self.details = details ?? Self.fetchDetails
        self.download = download ?? SteamInputDefaultSources.fetchBytes
    }
    static func search(_ text: String) -> String { String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)) }
    private func pageURL(appID: UInt32, order: Order, text: String, page: UInt32) -> URL {
        let key = DockSteamInputNative.contentHash(Data("\(order.rawValue):\(page):\(text)".utf8))
        return root.appendingPathComponent("\(appID)/pages/\(key).json")
    }
    private static func associated(_ item: SteamWorkshopItem, appID: UInt32) -> Bool {
        let association = item.kvTags?.filter { $0.key.lowercased() == "app" }.map(\.value) ?? []
        let visibility = item.kvTags?.filter { $0.key.lowercased() == "visibility" }.map(\.value) ?? []
        let deleted = item.kvTags?.filter { $0.key.lowercased() == "deleted" }.map(\.value) ?? []
        return item.id > 0 && item.appID == 241100 && item.result == 1 && !item.banned && item.incompatible != true &&
            (item.visibility ?? 0) == 0 && item.fileType == 12 && item.fileSize > 0 && item.fileSize <= limit &&
            SteamInputDefaultSources.downloadURL(item.fileURL) != nil && association == [String(appID)] &&
            visibility == ["public"] && deleted == ["0"]
    }
    func page(appID: UInt32, order: Order, text: String, number: UInt32, refresh: Bool = false) async throws -> Page {
        guard appID > 0, (1...100).contains(number) else { throw Failure.invalid }
        let text = Self.search(text), url = pageURL(appID: appID, order: order, text: Self.search(text), page: number)
        if !refresh, FileManager.default.fileExists(atPath: url.path) {
            let saved = try JSONDecoder().decode(Page.self, from: Self.read(url, limit: 512 << 10))
            guard saved.version == 1, saved.appID == appID, saved.order == order, saved.text == text,
                  saved.number == number, saved.items.count <= 30, saved.items.allSatisfy({ Self.associated($0, appID: appID) }) else { throw Failure.invalid }
            return saved
        }
        try Task.checkCancellation()
        let result = try await query(appID, order, text, number)
        try Task.checkCancellation()
        guard result.items.count <= 30, Set(result.items.map(\.id)).count == result.items.count else { throw Failure.invalid }
        let saved = Page(appID: appID, order: order, text: text, number: number, total: result.total,
                         items: result.items.filter { Self.associated($0, appID: appID) }, fetched: Date())
        let encoded = try JSONEncoder().encode(saved)
        guard encoded.count <= 512 << 10 else { throw Failure.invalid }
        try write(encoded, to: url)
        if refresh, number == 1 {
            // Page boundaries can shift after an update. Later pages from the
            // preceding listing must not be appended to the new first page.
            for page in UInt32(2)...100 {
                let stale = pageURL(appID: appID, order: order, text: text, page: page)
                if FileManager.default.fileExists(atPath: stale.path) { try FileManager.default.removeItem(at: stale) }
            }
        }
        return saved
    }
    private func itemDirectory(appID: UInt32, id: UInt64) -> URL { root.appendingPathComponent("\(appID)/items/\(id)") }
    private func objectURL(appID: UInt32, id: UInt64, hash: String) throws -> URL {
        guard appID > 0, id > 0, Self.validHash(hash) else { throw Failure.invalid }
        return itemDirectory(appID: appID, id: id).appendingPathComponent(hash + ".vdf")
    }
    private static func validHash(_ hash: String) -> Bool {
        hash.utf8.count == 64 && hash.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    func cached(appID: UInt32, id: UInt64) throws -> [Revision] {
        guard appID > 0, id > 0 else { throw Failure.invalid }
        let url = itemDirectory(appID: appID, id: id).appendingPathComponent("revisions.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let values = try JSONDecoder().decode([Revision].self, from: Self.read(url, limit: 256 << 10))
        guard values.count <= 32, Set(values.map(\.hash)).count == values.count,
              values.allSatisfy({ $0.version == 1 && $0.appID == appID && $0.item.id == id && Self.associated($0.item, appID: appID) && Self.validHash($0.hash) }) else { throw Failure.invalid }
        return values
    }
    func downloaded(appID: UInt32) throws -> [Revision] {
        guard appID > 0 else { throw Failure.invalid }
        let directory = root.appendingPathComponent("\(appID)/items")
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let children = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        guard children.count <= 1024 else { throw Failure.invalid }
        return try children.compactMap { url -> Revision? in
            guard let id = UInt64(url.lastPathComponent), id > 0, String(id) == url.lastPathComponent else { return nil }
            return try cached(appID: appID, id: id).first
        }.sorted { $0.downloaded > $1.downloaded }
    }
    func load(_ revision: Revision) throws -> Layout {
        guard revision.version == 1, Self.associated(revision.item, appID: revision.appID) else { throw Failure.invalid }
        let bytes = try Self.read(objectURL(appID: revision.appID, id: revision.item.id, hash: revision.hash), limit: Self.limit)
        guard bytes.count == revision.item.fileSize, DockSteamInputNative.contentHash(bytes) == revision.hash else { throw Failure.invalid }
        _ = try DockSteamInputNative.revision(bytes)
        return Layout(revision: revision, bytes: bytes, compatibility: try SteamInputCompatibility(bytes, tags: revision.item.tags ?? []))
    }
    /// Recover Steam's exact selected item, preferring a verified offline
    /// revision. This supplies a baseline without recording explicit user intent.
    func selectedWorkshop(appID: UInt32, itemID: UInt64) async throws -> Data {
        let layout: Layout
        if let revision = try cached(appID: appID, id: itemID).first {
            layout = try load(revision)
        } else {
            let item = try await latest(appID: appID, id: itemID)
            layout = try await download(appID: appID, item: item)
        }
        guard layout.compatibility.canApply else { throw Failure.incompatible }
        return layout.bytes
    }
    /// Checking for updates does not download or replace any revision.
    func latest(appID: UInt32, id: UInt64) async throws -> SteamWorkshopItem {
        guard appID > 0, id > 0 else { throw Failure.invalid }
        let items = try await details([id])
        try Task.checkCancellation()
        guard items.count == 1, let item = items.first, item.id == id, Self.associated(item, appID: appID) else { throw Failure.unavailable }
        return item
    }
    /// Pure, non-persisting ephemeral preview fetch. Zero disk writes, zero journal touches.
    /// It holds no transfer slot: it writes nothing a second fetch could race, and a
    /// cancelled fetch that has not unwound yet must not block the player's retry.
    /// `actions` is where the game's own action names come from; it is only shown, never stored.
    func preview(appID: UInt32, item: SteamWorkshopItem, actions: SteamInputActionNames) async throws -> SteamInputPreviewData {
        guard Self.associated(item, appID: appID) else { throw Failure.invalid }

        let before = try await latest(appID: appID, id: item.id)
        guard Revision.sameContent(before, item) else { throw Failure.changed }
        let bytes = try await download(try SteamInputDefaultSources.downloadURL(before.fileURL).unwrap())
        try Task.checkCancellation()
        guard bytes.count == before.fileSize, !bytes.isEmpty, bytes.count <= Self.limit else { throw Failure.invalid }

        let document = try VDFDocument.parse(bytes)
        let after = try await latest(appID: appID, id: item.id)
        guard Revision.sameContent(before, after) else { throw Failure.changed }
        try Task.checkCancellation()

        let model = try SteamInputLayoutModel(document: document)
        return SteamInputPreviewData(model: model, actions: actions)
    }

    func download(appID: UInt32, item: SteamWorkshopItem) async throws -> Layout {
        guard Self.associated(item, appID: appID) else { throw Failure.invalid }
        if let saved = try cached(appID: appID, id: item.id).first(where: { $0.matches(item) }) { return try load(saved) }
        let key = "\(appID):\(item.id)"
        guard transfers.insert(key).inserted else { throw Failure.busy }
        defer { transfers.remove(key) }
        let before = try await latest(appID: appID, id: item.id)
        guard Revision.sameContent(before, item) else { throw Failure.changed }
        let bytes = try await download(try SteamInputDefaultSources.downloadURL(before.fileURL).unwrap())
        try Task.checkCancellation()
        guard bytes.count == before.fileSize, !bytes.isEmpty, bytes.count <= Self.limit else { throw Failure.invalid }
        _ = try DockSteamInputNative.revision(bytes)
        let compatibility = try SteamInputCompatibility(bytes, tags: before.tags ?? [])
        let after = try await latest(appID: appID, id: item.id)
        guard Revision.sameContent(before, after) else { throw Failure.changed }
        try Task.checkCancellation()
        let revision = Revision(appID: appID, item: before, hash: DockSteamInputNative.contentHash(bytes), downloaded: Date())
        let object = try objectURL(appID: appID, id: item.id, hash: revision.hash)
        if FileManager.default.fileExists(atPath: object.path) {
            guard try Self.read(object, limit: Self.limit) == bytes else { throw Failure.invalid }
        } else { try write(bytes, to: object) }
        var history = try cached(appID: appID, id: item.id)
        history.removeAll { $0.hash == revision.hash }; history.insert(revision, at: 0)
        let encoded = try JSONEncoder().encode(Array(history.prefix(32)))
        guard encoded.count <= 256 << 10 else { throw Failure.invalid }
        try write(encoded, to: itemDirectory(appID: appID, id: item.id).appendingPathComponent("revisions.json"))
        return Layout(revision: revision, bytes: bytes, compatibility: compatibility)
    }
    private func write(_ bytes: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url, options: .atomic)
    }
    static func read(_ url: URL, limit: Int) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw Failure.invalid }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size > 0, info.st_size <= limit,
              let bytes = try file.read(upToCount: limit + 1), bytes.count == info.st_size else { throw Failure.invalid }
        var after = stat()
        guard fstat(fd, &after) == 0, info.st_size == after.st_size,
              info.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, info.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              info.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, info.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw Failure.invalid }
        return bytes
    }
    private static func fetchPage(appID: UInt32, order: Order, text: String, page: UInt32) async throws -> SteamWorkshopPage {
        try await session.ensureConnected()
        let response = try await session.callServiceMethodWithResult(method: .workshopQueryFiles,
            body: SteamWorkshopRequests.controllerQuery(appID: appID, order: order.rawValue, text: text, page: page), timeout: 20)
        guard response.eresult == 1, response.body.count <= 2 << 20 else { throw Failure.unavailable }
        return try SteamWorkshopRequests.page(response.body, itemsField: 2)
    }
    private static func fetchDetails(_ ids: [UInt64]) async throws -> [SteamWorkshopItem] {
        try await session.ensureConnected()
        let response = try await session.callServiceMethodWithResult(method: .workshopGetDetails,
            body: SteamWorkshopRequests.controllerDetails(ids), timeout: 20)
        guard response.eresult == 1, response.body.count <= 2 << 20 else { throw Failure.unavailable }
        return try SteamWorkshopRequests.page(response.body, itemsField: 1, totalField: nil).items
    }
}

/// A personal layout is exact bytes the player keeps under their own name:
/// a copy of a community layout (never an edit of its original) or a VDF file
/// they imported. It is stored under its own UUID and can be applied as the
/// player's choice. Editing and revision history are later milestone 4 items.
///
/// Personal layouts are local. They live in the app's own storage and reach
/// Valve's engine only as bytes handed to the pinned loader; nothing puts
/// them in the account's Steam Cloud, so the app never says they are synced
/// or backed up. Export and import are the way to move or keep one.
struct SteamInputPersonalCopy: Codable, Identifiable {
    var version = 1
    let id: UUID
    let accountID: UInt32
    let appID: UInt32
    let title: String
    /// The community revision this was copied from; nil for an imported file.
    let origin: SteamInputCommunitySources.Revision?
    let hash: String
    /// When an imported file was imported, and the name it had.
    var imported: Date? = nil
    var sourceName: String? = nil

    /// Said wherever a personal layout is listed or shown.
    static let storageNote = "Stored on this device only. Personal layouts are not synced or backed up to Steam Cloud; export the VDF to keep a copy or move it to another device."
    /// Where the layout came from, for its row and page.
    var provenance: String {
        if let origin { return "Copied from " + origin.attribution }
        return "Imported" + (sourceName.map { " from " + $0 } ?? " VDF file")
    }
    static func folder(root: URL, accountID: UInt32, appID: UInt32) -> URL {
        root.appendingPathComponent("SteamInputPersonal/\(accountID)/\(appID)")
    }
    @MainActor static func list(root: URL, accountID: UInt32, appID: UInt32) throws -> [Self] {
        guard accountID > 0, appID > 0 else { return [] }
        let directory = folder(root: root, accountID: accountID, appID: appID)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let children = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        guard children.count <= 1024 else { throw SteamInputCommunitySources.Failure.invalid }
        return try children.compactMap { url -> Self? in
            guard let id = UUID(uuidString: url.lastPathComponent) else { return nil }
            let value = try JSONDecoder().decode(Self.self, from: SteamInputCommunitySources.read(url.appendingPathComponent("layout.json"), limit: 256 << 10))
            guard value.version == 1, value.id == id, value.accountID == accountID, value.appID == appID,
                  value.hash.utf8.count == 64, value.hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  value.origin.map({ $0.appID == appID && $0.hash == value.hash }) ?? true else { throw SteamInputCommunitySources.Failure.invalid }
            return value
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    @MainActor func source(root: URL) throws -> URL {
        let url = Self.folder(root: root, accountID: accountID, appID: appID).appendingPathComponent(id.uuidString + "/source.vdf")
        let bytes = try SteamInputCommunitySources.read(url, limit: SteamInputCommunitySources.limit)
        guard DockSteamInputNative.contentHash(bytes) == hash else { throw SteamInputCommunitySources.Failure.invalid }
        return url
    }
    /// The stored layout, read without following links and checked against the recorded hash.
    @MainActor func bytes(root: URL) throws -> Data {
        try SteamInputCommunitySources.read(source(root: root), limit: SteamInputCommunitySources.limit)
    }
    /// Shown with the active choice. At most 512 UTF-8 bytes, as the selection store requires.
    var detail: String {
        var text = title + (origin.map { " · personal copy of " + $0.attribution } ?? " · imported VDF file")
        while text.utf8.count > 512 { text.removeLast() }
        return text
    }
    /// Everything the layout service needs to apply this layout.
    struct ApplyRequest: Equatable {
        let appID: UInt32
        let accountID: UInt32
        let id: UUID
        let source: Data
        let detail: String
        let compatibility: SteamInputCompatibility
    }
    enum ApplyFailure: LocalizedError, Equatable {
        case incompatible(String)
        /// The stored file is missing, is not a plain file or no longer matches its record.
        case damaged
        /// The bytes are not a layout Steam Input's loader accepts.
        case notALayout
        var errorDescription: String? {
            switch self {
            case .incompatible(let reason): return "This layout cannot be applied. " + reason
            case .damaged: return "This layout cannot be applied. Its stored file is missing or was changed outside Madeira."
            case .notALayout: return "This layout cannot be applied. It is not a valid Steam Input layout."
            }
        }
    }
    /// Reads the stored bytes afresh and puts them through the same checks as
    /// a community layout before anything is handed to the layout service: the
    /// recorded hash, the rejection of conditional layouts, the reference
    /// check, the native metadata reader and the inputs Madeira can forward.
    /// The journal reads the revision again when it prepares the change.
    /// Nothing is written, and the community original is not opened.
    @MainActor func applyRequest(root: URL) throws -> ApplyRequest {
        let source: Data
        do { source = try bytes(root: root) } catch { throw ApplyFailure.damaged }
        let compatibility: SteamInputCompatibility
        // A conditional layout and a broken reference keep their own wording.
        do { compatibility = try SteamInputCompatibility(source, tags: origin?.item.tags ?? []) }
        catch is SteamInputCommunitySources.Failure { throw ApplyFailure.notALayout }
        guard compatibility.canApply else { throw ApplyFailure.incompatible(compatibility.description) }
        return ApplyRequest(appID: appID, accountID: accountID, id: id, source: source, detail: detail, compatibility: compatibility)
    }
    @MainActor static func create(_ layout: SteamInputCommunitySources.Layout, title: String, accountID: UInt32, root: URL) throws -> Self {
        let title = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
        guard accountID > 0, !title.isEmpty, !title.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              DockSteamInputNative.contentHash(layout.bytes) == layout.revision.hash else { throw SteamInputCommunitySources.Failure.invalid }
        let copy = Self(id: UUID(), accountID: accountID, appID: layout.revision.appID, title: title, origin: layout.revision, hash: layout.revision.hash)
        try copy.store(layout.bytes, root: root)
        return copy
    }
    /// Both files appear together or not at all.
    private func store(_ bytes: Data, root: URL) throws {
        let encoded = try JSONEncoder().encode(self)
        guard encoded.count <= 256 << 10 else { throw SteamInputCommunitySources.Failure.invalid }
        let parent = Self.folder(root: root, accountID: accountID, appID: appID)
        let staging = parent.appendingPathComponent(".\(id.uuidString).tmp")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        try bytes.write(to: staging.appendingPathComponent("source.vdf"), options: .atomic)
        try encoded.write(to: staging.appendingPathComponent("layout.json"), options: .atomic)
        try FileManager.default.moveItem(at: staging, to: parent.appendingPathComponent(id.uuidString))
    }

    // MARK: Import and export

    enum ImportFailure: LocalizedError, Equatable {
        case unreadable, tooLarge, notALayout, tooMany, noAccount
        case invalidLayout(String)
        var errorDescription: String? {
            switch self {
            case .unreadable: return "The file could not be read."
            case .tooLarge: return "The file is too large to be a Steam Input layout."
            case .notALayout: return "The file is not a valid Steam Input layout, so it was not imported."
            case .invalidLayout(let reason): return "The file was not imported. " + reason
            case .tooMany: return "This game already has the most personal layouts Madeira keeps. Nothing was imported."
            case .noAccount: return "Sign in to Steam before importing a layout: personal layouts are kept per account."
            }
        }
    }
    /// How many personal layouts one account keeps for one game.
    static let limit = 256

    /// A picked file's bytes, bounded before anything is parsed. The file is
    /// only read; Madeira keeps its own copy.
    @MainActor static func readImport(_ url: URL) throws -> Data {
        guard let file = try? FileHandle(forReadingFrom: url) else { throw ImportFailure.unreadable }
        defer { try? file.close() }
        guard let bytes = try? file.read(upToCount: SteamInputCommunitySources.limit + 1), !bytes.isEmpty else { throw ImportFailure.unreadable }
        guard bytes.count <= SteamInputCommunitySources.limit else { throw ImportFailure.tooLarge }
        return bytes
    }
    /// A layout's name taken from a file name: its extension and anything that is not printable removed.
    static func importTitle(fileName: String) -> String {
        var name = (fileName as NSString).lastPathComponent
        if name.lowercased().hasSuffix(".vdf") { name.removeLast(4) }
        name = String(String.UnicodeScalarView(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
        name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
        return name.isEmpty ? "Imported layout" : name
    }
    /// Keeps the file's exact bytes as a new personal layout for this account
    /// and game. The file must pass the same checks as a community layout
    /// (conditional layouts rejected, references resolved, the native reader);
    /// a layout that only needs inputs Madeira cannot forward is kept and
    /// cannot be applied, like a downloaded one. Nothing is selected or
    /// applied, and a refused file leaves nothing behind.
    @MainActor static func importVDF(_ bytes: Data, fileName: String, accountID: UInt32, appID: UInt32, root: URL,
                                     now: Date = Date()) throws -> Self {
        guard accountID > 0 else { throw ImportFailure.noAccount }
        guard appID > 0, !bytes.isEmpty else { throw ImportFailure.notALayout }
        guard bytes.count <= SteamInputCommunitySources.limit else { throw ImportFailure.tooLarge }
        do { _ = try SteamInputCompatibility(bytes) }
        catch is SteamInputCommunitySources.Failure { throw ImportFailure.notALayout }
        catch SteamFileError.invalid(let reason) { throw ImportFailure.invalidLayout(reason) }
        guard (try? list(root: root, accountID: accountID, appID: appID).count) ?? limit < limit else { throw ImportFailure.tooMany }
        let name = String((fileName as NSString).lastPathComponent.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(120).map(String.init).joined())
        let copy = Self(id: UUID(), accountID: accountID, appID: appID, title: importTitle(fileName: fileName), origin: nil,
                        hash: DockSteamInputNative.contentHash(bytes), imported: now, sourceName: name.isEmpty ? nil : name)
        try copy.store(bytes, root: root)
        return copy
    }
    /// A copy of the stored bytes under a readable file name, for sharing.
    /// `directory` is a scratch location; the stored layout is not moved.
    @MainActor func exportFile(root: URL, directory: URL) throws -> URL {
        let data = try bytes(root: root)
        let unsafe = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters).union(.newlines)
        var name = String(String.UnicodeScalarView(title.unicodeScalars.map { unsafe.contains($0) ? " " : $0 }))
        name = String(name.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "."))).prefix(80))
        let folder = directory.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent((name.isEmpty ? "Steam Input layout" : name) + ".vdf")
        try data.write(to: url, options: .atomic)
        return url
    }
}
