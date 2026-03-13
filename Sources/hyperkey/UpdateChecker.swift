import Foundation

enum UpdateChecker {
    struct UpdateInfo: Sendable {
        let version: String
        let releasePageURL: String
        let downloadURL: String?
    }

    struct Release: Decodable {
        let tag_name: String
        let html_url: String
        let assets: [ReleaseAsset]
    }

    struct ReleaseAsset: Decodable {
        let name: String
        let browser_download_url: String
    }

    enum UpdateError: LocalizedError {
        case invalidResponse
        case githubStatus(Int)
        case decodeFailed
        case networkFailure(String)

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return L10n.tr(
                    "update_check.error.invalid_response",
                    default: "GitHub returned an invalid response while checking for updates."
                )
            case .githubStatus(let statusCode):
                return L10n.tr(
                    "update_check.error.github_status",
                    default: "GitHub returned HTTP %d while checking for updates.",
                    statusCode
                )
            case .decodeFailed:
                return L10n.tr(
                    "update_check.error.decode_failed",
                    default: "GitHub returned release data in an unexpected format."
                )
            case .networkFailure(let message):
                return L10n.tr(
                    "update_check.error.network_failure",
                    default: "Unable to reach GitHub: %@",
                    message
                )
            }
        }
    }

    private static let lastCheckKey = "lastUpdateCheck"
    private static let cachedVersionKey = "cachedUpdateVersion"
    private static let cachedURLKey = "cachedUpdateURL"
    private static let cachedDownloadURLKey = "cachedUpdateDownloadURL"
    private static let checkInterval: TimeInterval = 24 * 60 * 60 // 24 hours

    /// Check GitHub for a newer release. Returns (latestVersion, url) if an update is available.
    /// Uses a 24-hour cache unless force is true.
    static func check(force: Bool = false) async throws -> UpdateInfo? {
        let defaults = UserDefaults.standard

        // Return cached result if within 24 hours
        if !force,
           let lastCheck = defaults.object(forKey: lastCheckKey) as? Date,
           Date().timeIntervalSince(lastCheck) < checkInterval
        {
            guard let version = defaults.string(forKey: cachedVersionKey),
                  let releasePageURL = defaults.string(forKey: cachedURLKey) else {
                return nil
            }

            guard isNewer(version, than: Constants.version) else {
                defaults.removeObject(forKey: cachedVersionKey)
                defaults.removeObject(forKey: cachedURLKey)
                defaults.removeObject(forKey: cachedDownloadURLKey)
                return nil
            }

            if let downloadURL = defaults.string(forKey: cachedDownloadURLKey) {
                return UpdateInfo(
                    version: version,
                    releasePageURL: releasePageURL,
                    downloadURL: downloadURL
                )
            }
        }

        let urlString = "https://api.github.com/repos/\(Constants.githubRepo)/releases/latest"
        guard let url = URL(string: urlString) else {
            throw UpdateError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        let data: Data
        let response: URLResponse

        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw UpdateError.networkFailure(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw UpdateError.invalidResponse
        }
        guard http.statusCode == 200 else {
            throw UpdateError.githubStatus(http.statusCode)
        }
        guard let release = try? JSONDecoder().decode(Release.self, from: data) else {
            throw UpdateError.decodeFailed
        }

        let latest = release.tag_name.hasPrefix("v")
            ? String(release.tag_name.dropFirst())
            : release.tag_name
        let downloadURL = release.assets.first(where: { $0.name == Constants.releaseAssetName })?.browser_download_url
            ?? release.assets.first(where: { $0.name.lowercased().hasSuffix(".zip") })?.browser_download_url

        // Cache the result
        defaults.set(Date(), forKey: lastCheckKey)

        if isNewer(latest, than: Constants.version) {
            defaults.set(latest, forKey: cachedVersionKey)
            defaults.set(release.html_url, forKey: cachedURLKey)
            if let downloadURL {
                defaults.set(downloadURL, forKey: cachedDownloadURLKey)
            } else {
                defaults.removeObject(forKey: cachedDownloadURLKey)
            }
            return UpdateInfo(
                version: latest,
                releasePageURL: release.html_url,
                downloadURL: downloadURL
            )
        }

        defaults.removeObject(forKey: cachedVersionKey)
        defaults.removeObject(forKey: cachedURLKey)
        defaults.removeObject(forKey: cachedDownloadURLKey)
        return nil
    }

    private static func isNewer(_ a: String, than b: String) -> Bool {
        let aParts = a.split(separator: ".").compactMap { Int($0) }
        let bParts = b.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(aParts.count, bParts.count) {
            let av = i < aParts.count ? aParts[i] : 0
            let bv = i < bParts.count ? bParts[i] : 0
            if av > bv { return true }
            if av < bv { return false }
        }
        return false
    }
}
