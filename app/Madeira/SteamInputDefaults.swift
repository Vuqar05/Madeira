// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Foundation
import Darwin

/// Public recommendation data uses an anonymous CM connection. It never reads
/// the signed-in account or takes the account away from a running Dock session.
/// Layouts remain original VDF bytes; Valve's engine interprets their bindings.
@MainActor final class SteamInputDefaultSources {
    static let shared = SteamInputDefaultSources()
    private static let session = SteamSession(anonymous: true)
    private static let limit = (1 << 20) - 1
    typealias Details = ([UInt64]) async throws -> [SteamWorkshopItem]
    typealias Download = (URL) async throws -> Data
    private let root: URL
    private let details: Details
    private let download: Download

    init(root: URL? = nil, details: Details? = nil, download: Download? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SteamInputDefaults", isDirectory: true)
        self.details = details ?? Self.fetchDetails
        self.download = download ?? Self.fetchBytes
    }

    static func metadata(appID: UInt32) async throws -> SteamAppInfo.SteamInputMetadata? {
        try Task.checkCancellation()
        return try await SteamLibraryFetcher(session: session).fetchAppInfo(appID: appID)?.steamInputMetadata
    }

    private struct Cached: Codable {
        let appID: UInt32
        let itemID: UInt64
        let candidates: [UInt64]
        let updated: UInt32
        let hash: String
        let title: String
        var controllerMatched: Bool? = nil
    }
    enum Failure: Error { case unavailable, invalid, incompatible }

    /// PICS's ordered list, not a community search, establishes game association.
    /// January chooses the first compatible (PS4 or PS5) listed layout, not the
    /// first PS5 layout. A failed earlier download cannot be silently skipped.
    func recommendation(appID: UInt32, ids: [UInt64], refresh: Bool = false, controllerMatched: Bool = false) async throws -> DockSteamInputDefault.Recommendation {
        guard appID > 0, !ids.isEmpty, ids.count <= 32, ids.allSatisfy({ $0 > 0 }), Set(ids).count == ids.count else {
            throw Failure.invalid
        }
        try Task.checkCancellation()
        if !refresh, let cached = try cached(appID: appID, ids: ids, controllerMatched: controllerMatched) { return cached }
        let items = try await details(ids)
        guard items.count == ids.count, Set(items.map(\.id)) == Set(ids) else { throw Failure.unavailable }
        for id in ids {
            try Task.checkCancellation()
            guard let item = items.first(where: { $0.id == id }), item.result == 1, !item.banned,
                  item.appID == 241100, item.fileType == 12, item.fileSize > 0, item.fileSize <= Self.limit,
                  let url = Self.downloadURL(item.fileURL) else { throw Failure.unavailable }
            let bytes = try await download(url)
            try Task.checkCancellation()
            guard bytes.count == Int(item.fileSize), !bytes.isEmpty, bytes.count <= Self.limit else { throw Failure.invalid }
            _ = try DockSteamInputNative.revision(bytes)
            guard let type = Self.controllerType(bytes) else { throw Failure.invalid }
            guard controllerMatched || ["controller_ps4", "controller_ps5"].contains(type.lowercased()) else { continue }
            let record = Cached(appID: appID, itemID: id, candidates: ids, updated: item.timeUpdated,
                                hash: DockSteamInputNative.contentHash(bytes), title: item.title, controllerMatched: controllerMatched)
            let directory = root.appendingPathComponent(String(appID), isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // A failed refresh leaves the last complete record/object pair intact.
            try bytes.write(to: directory.appendingPathComponent(record.hash + ".vdf"), options: .atomic)
            try JSONEncoder().encode(record).write(to: directory.appendingPathComponent("default.json"), options: .atomic)
            return Self.recommendation(record, bytes: bytes)
        }
        throw Failure.incompatible
    }

    private func cached(appID: UInt32, ids: [UInt64], controllerMatched: Bool) throws -> DockSteamInputDefault.Recommendation? {
        let directory = root.appendingPathComponent(String(appID), isDirectory: true)
        let path = directory.appendingPathComponent("default.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let record = try JSONDecoder().decode(Cached.self, from: Self.read(path, limit: 8192))
        guard record.appID == appID, record.hash.utf8.count == 64,
              record.hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw Failure.invalid }
        guard record.candidates == ids, ids.contains(record.itemID), (record.controllerMatched ?? false) == controllerMatched else { return nil }
        let bytes = try Self.read(directory.appendingPathComponent(record.hash + ".vdf"), limit: Self.limit)
        guard DockSteamInputNative.contentHash(bytes) == record.hash,
              let type = Self.controllerType(bytes), controllerMatched || ["controller_ps4", "controller_ps5"].contains(type.lowercased()) else {
            throw Failure.invalid
        }
        _ = try DockSteamInputNative.revision(bytes)
        return Self.recommendation(record, bytes: bytes)
    }

    private static func recommendation(_ record: Cached, bytes: Data) -> DockSteamInputDefault.Recommendation {
        var value = DockSteamInputDefault.Recommendation(source: bytes, origin: .workshop)
        value.attribution = "Workshop item \(record.itemID): \(String(record.title.prefix(200)))"
        return value
    }
    nonisolated static func controllerType(_ bytes: Data) -> String? {
        var type = [CChar](repeating: 0, count: 64)
        let valid = bytes.withUnsafeBytes { raw in
            guard let address = raw.baseAddress else { return false }
            return sh_input_vdf_controller_type(address.assumingMemoryBound(to: CChar.self), bytes.count, &type, type.count)
        }
        return valid ? String(validatingUTF8: type) : nil
    }
    private static func read(_ url: URL, limit: Int) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw Failure.invalid }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_size > 0, before.st_size <= limit,
              let bytes = try file.read(upToCount: limit + 1), bytes.count == Int(before.st_size) else { throw Failure.invalid }
        var after = stat()
        guard fstat(descriptor, &after) == 0, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw Failure.invalid }
        return bytes
    }
    nonisolated static func downloadURL(_ text: String) -> URL? {
        // Older public items name HTTP URLs; contact the same verified CDN
        // over HTTPS only. Redirects never downgrade the connection.
        let secure = text.hasPrefix("http://") ? "https://" + text.dropFirst(7) : text
        guard let url = URL(string: secure), allowed(url) else { return nil }
        return url
    }
    nonisolated static func allowed(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil || url.port == 443,
              let host = url.host?.lowercased() else { return false }
        return ["steamusercontent.com", "steamstatic.com", "steamcontent.com", "akamaihd.net"].contains {
            host == $0 || host.hasSuffix("." + $0)
        }
    }
    private static func fetchDetails(_ ids: [UInt64]) async throws -> [SteamWorkshopItem] {
        try await session.ensureConnected()
        let response = try await session.callServiceMethodWithResult(method: .workshopGetDetails,
            body: SteamWorkshopRequests.details(appID: 241100, ids: ids), timeout: 20)
        guard response.eresult == 1, response.body.count <= 2 << 20 else { throw Failure.unavailable }
        return try SteamWorkshopRequests.page(response.body, itemsField: 1, totalField: nil).items
    }
    static func fetchBytes(_ url: URL) async throws -> Data { try await fetchBytes(url, protocols: nil) }
    /// `protocols` lets a host check answer the request in-process, so the real
    /// session, redirect delegate, response checks and byte limit run offline.
    static func fetchBytes(_ url: URL, protocols: [AnyClass]?) async throws -> Data {
        guard allowed(url) else { throw Failure.invalid }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 30
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        if let protocols { config.protocolClasses = protocols }
        let session = URLSession(configuration: config, delegate: SteamInputDefaultRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (stream, response) = try await session.bytes(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let finalURL = http.url, allowed(finalURL), response.expectedContentLength <= limit else { throw Failure.unavailable }
        return try await collect(stream, limit: limit)
    }
    /// Keeps at most `limit` bytes. The byte that would exceed it fails the
    /// transfer at once, without reading the rest of a body whose length the
    /// server understated or did not declare. Cancellation stops before the
    /// next byte is kept. Runs off the main actor; it touches no shared state.
    nonisolated static func collect<Stream: AsyncSequence & Sendable>(_ stream: Stream, limit: Int) async throws -> Data where Stream.Element == UInt8 {
        var bytes = Data()
        for try await byte in stream {
            try Task.checkCancellation()
            guard bytes.count < limit else { throw Failure.invalid }
            bytes.append(byte)
        }
        return bytes
    }
}

public final class SteamInputDefaultRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    public override init() { super.init() }
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // The policy is pure; callback queues do not read the main-actor cache/session.
        let allowed = request.url.map(SteamInputDefaultSources.allowed) ?? false
        completionHandler(allowed ? request : nil)
    }
}

