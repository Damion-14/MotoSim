import Foundation

enum TrackTransfer {
    static let defaultServerAddress = Bundle.main.object(forInfoDictionaryKey: "MotoSimServerURL") as? String ?? ""

    enum Failure: LocalizedError {
        case configuration, denied, expired, transferFailed

        var errorDescription: String? {
            switch self {
            case .configuration: "Enter your track server’s HTTPS address and upload key."
            case .denied: "The track server rejected the upload key."
            case .expired: "The shared track expired. Ask the host to create a new Free Ride."
            case .transferFailed: "The track server could not transfer this track. Try again."
            }
        }
    }

    private struct Receipt: Decodable {
        let grant: String
        let sha256: String
    }

    private final class TransferLimits: NSObject, URLSessionTaskDelegate, URLSessionDownloadDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {}

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            if max(totalBytesWritten, totalBytesExpectedToWrite) > SharedTrack.maxBytes { downloadTask.cancel() }
        }
    }

    static func serverURL(_ text: String) -> URL? {
        guard let components = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == "https", let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil, components.query == nil,
              components.fragment == nil else { return nil }
        return components.url
    }

    static func upload(_ track: Track, server: URL, key: String) async throws -> TrackDownload {
        let data = try SharedTrack.encode(track)
        var request = URLRequest(url: server.appending(path: "v1/tracks"), timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        let session = session()
        defer { session.finishTasksAndInvalidate() }
        let (file, response) = try await session.upload(for: request, from: data, delegate: TransferLimits())
        let status = (response as? HTTPURLResponse)?.statusCode
        if status == 401 { throw Failure.denied }
        if status == 413 || status == 422 { throw SharedTrack.Failure.invalid }
        guard status == 201, file.count <= 4096 else { throw Failure.transferFailed }
        let receipt = try JSONDecoder().decode(Receipt.self, from: file)
        guard SharedTrack.hash(data) == receipt.sha256, validGrant(receipt.grant) else { throw SharedTrack.Failure.mismatch }
        return TrackDownload(server: server, grant: receipt.grant, sha256: receipt.sha256)
    }

    static func load(_ download: TrackDownload, name: String, current: Track) async throws -> Track {
        guard let server = serverURL(download.server.absoluteString), validGrant(download.grant),
              SharedTrack.validHash(download.sha256) else { throw SharedTrack.Failure.invalid }
        if let data = try? SharedTrack.encode(current), SharedTrack.hash(data) == download.sha256 {
            var track = current
            track.name = name
            return track
        }
        let cache = cacheLocation(download.sha256)
        if let cache, let data = try? readPackage(cache), SharedTrack.hash(data) == download.sha256,
           let track = try? SharedTrack.decode(data, name: name) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: cache.path)
            return track
        }
        let request = URLRequest(url: server.appending(path: "v1/tracks").appending(path: download.grant),
                                 timeoutInterval: 120)
        let session = session()
        defer { session.finishTasksAndInvalidate() }
        let (file, response) = try await session.download(for: request, delegate: TransferLimits())
        defer { try? FileManager.default.removeItem(at: file) }
        let status = (response as? HTTPURLResponse)?.statusCode
        if status == 404 || status == 410 { throw Failure.expired }
        guard status == 200 else { throw Failure.transferFailed }
        let data = try readPackage(file)
        guard SharedTrack.hash(data) == download.sha256 else { throw SharedTrack.Failure.mismatch }
        let track = try SharedTrack.decode(data, name: name)
        if let cache {
            try? data.write(to: cache, options: .atomic)
            pruneCache(keep: cache)
        }
        return track
    }

    private static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = 240
        let delegate = TransferLimits()
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    private static func readPackage(_ url: URL) throws -> Data {
        guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              (1...SharedTrack.maxBytes).contains(size) else { throw SharedTrack.Failure.invalid }
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }

    private static func validGrant(_ grant: String) -> Bool {
        let parts = grant.split(separator: ".", omittingEmptySubsequences: false)
        return grant.utf8.count <= 110 && parts.count == 3 && parts[0].utf8.count == 32 &&
            parts[0].utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } &&
            Int(parts[1]) != nil && SharedTrack.validHash(String(parts[2]))
    }

    private static func cacheLocation(_ hash: String) -> URL? {
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let directory = base.appending(path: "SharedTracks", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory.appending(path: hash)
        } catch {
            return nil
        }
    }

    private static func pruneCache(keep: URL) {
        let directory = keep.deletingLastPathComponent()
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
                     includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let old = files.filter { $0 != keep }.map { file in
            (file, (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }.sorted { $0.1 > $1.1 }
        for (file, _) in old.dropFirst(3) { try? FileManager.default.removeItem(at: file) }
    }
}
