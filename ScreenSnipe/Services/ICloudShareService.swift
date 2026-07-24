import Foundation

enum ICloudShareError: LocalizedError {
    case notSignedIn
    case containerUnavailable
    case uploadTimedOut

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            "Sharing via iCloud link requires being signed into iCloud with iCloud Drive enabled. Check System Settings > Apple ID."
        case .containerUnavailable:
            "The app's iCloud container is unavailable. This build may not be provisioned for iCloud."
        case .uploadTimedOut:
            "Uploading to iCloud took too long. Check your network connection and try again."
        }
    }
}

/// Publishes captures as public iCloud download links via
/// `FileManager.url(forPublishingUbiquitousItemAt:expiration:)`.
///
/// Shared files live in a `SharedLinks/` subfolder of the app's ubiquity container
/// (outside `Documents/` so no user-facing iCloud Drive folder appears), named by
/// library entry id so links can be revoked later. The expiration date is chosen
/// by the system and returned to the caller.
enum ICloudShareService {
    static let containerIdentifier = "iCloud.app.screensnipe.app"
    private static let sharedFolderName = "SharedLinks"
    private static let uploadTimeout: TimeInterval = 10 * 60
    private static let uploadPollInterval: Duration = .milliseconds(500)

    struct PublishedLink: Sendable {
        let url: URL
        let expiration: Date?
    }

    /// Publishes in-memory data (a flattened screenshot) as a public iCloud link.
    static func publish(data: Data, entryID: String, fileExtension: String) async throws -> PublishedLink {
        let destination = try containerFileURL(entryID: entryID, fileExtension: fileExtension)
        try? FileManager.default.removeItem(at: destination)
        try data.write(to: destination)
        return try await publishContainerFile(at: destination)
    }

    /// Publishes a copy of an existing file (a recording) as a public iCloud link.
    static func publish(fileAt sourceURL: URL, entryID: String) async throws -> PublishedLink {
        let destination = try containerFileURL(entryID: entryID, fileExtension: sourceURL.pathExtension)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        return try await publishContainerFile(at: destination)
    }

    /// Deletes the entry's file from the iCloud container, which invalidates all
    /// links published for it.
    static func revoke(entryID: String) async throws {
        guard let containerURL = containerURL() else { return }
        let folder = containerURL.appendingPathComponent(sharedFolderName)
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        for file in contents where file.deletingPathExtension().lastPathComponent == entryID {
            try fm.removeItem(at: file)
        }
    }

    // MARK: - Helpers

    /// Must not be called on the main thread: `url(forUbiquityContainerIdentifier:)`
    /// can block while iCloud sets up the container.
    private static func containerURL() -> URL? {
        FileManager.default.url(forUbiquityContainerIdentifier: containerIdentifier)
    }

    private static func containerFileURL(entryID: String, fileExtension: String) throws -> URL {
        guard FileManager.default.ubiquityIdentityToken != nil else {
            throw ICloudShareError.notSignedIn
        }
        guard let containerURL = containerURL() else {
            throw ICloudShareError.containerUnavailable
        }
        let folder = containerURL.appendingPathComponent(sharedFolderName)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(entryID).appendingPathExtension(fileExtension)
    }

    private static func publishContainerFile(at url: URL) async throws -> PublishedLink {
        try await waitForUpload(of: url)
        var expiration: NSDate?
        let publicURL = try FileManager.default.url(forPublishingUbiquitousItemAt: url, expiration: &expiration)
        return PublishedLink(url: publicURL, expiration: expiration as Date?)
    }

    /// The publishing API fails unless the file is fully uploaded, so poll the
    /// ubiquitous resource values until iCloud reports the upload as complete.
    private static func waitForUpload(of url: URL) async throws {
        let deadline = Date(timeIntervalSinceNow: uploadTimeout)
        while Date() < deadline {
            try Task.checkCancellation()
            var freshURL = url
            freshURL.removeCachedResourceValue(forKey: .ubiquitousItemIsUploadedKey)
            let values = try freshURL.resourceValues(forKeys: [.ubiquitousItemIsUploadedKey])
            if values.ubiquitousItemIsUploaded == true { return }
            try await Task.sleep(for: uploadPollInterval)
        }
        throw ICloudShareError.uploadTimedOut
    }
}
