// A newer release shows as a small dot on the ⋯ (owner's pick, 2026-11-19).
// Nothing updates by itself: the ⋯ menu then offers the upgrade command for
// the way this copy was installed, and the release page.
//
// Cost: one small HTTPS request to GitHub, at most once a day, and only when
// the menu is opened — never from the menu-closed path. It is the app's only
// request outside the tailnet, and it carries nothing but the repository name.
import Foundation

/// A release newer than the running copy.
struct UpdateNotice: Equatable {
    var version: String // "0.4.1", no leading v
    var page: URL // the release page
}

enum UpdateCheck {
    static let latestURL = URL(string: "https://api.github.com/repos/barathanaslan/tailmon/releases/latest")!
    /// A found answer is good for a day.
    static let interval: TimeInterval = 86_400
    /// A failed request (offline, rate limit) is not repeated on every menu open.
    static let retryAfterFailure: TimeInterval = 3_600

    /// Numeric, part by part: "0.10.0" is newer than "0.9.3". A leading "v",
    /// a missing part ("0.4" == "0.4.0") and a suffix ("0.4.1-rc1" counts as
    /// 0.4.1) are all fine.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    static func parts(_ version: String) -> [Int] {
        var v = Substring(version)
        if v.first == "v" || v.first == "V" { v = v.dropFirst() }
        return v.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
    }

    /// GitHub's "latest release" answer: tag_name and html_url.
    static func parse(_ data: Data) -> UpdateNotice? {
        struct Release: Decodable {
            var tagName: String
            var htmlUrl: String
        }
        guard let r = try? tailmonJSONDecoder().decode(Release.self, from: data),
              let page = URL(string: r.htmlUrl), page.scheme == "https" else { return nil }
        let version = r.tagName.hasPrefix("v") ? String(r.tagName.dropFirst()) : r.tagName
        guard !parts(version).isEmpty, parts(version).contains(where: { $0 > 0 }) else { return nil }
        return UpdateNotice(version: version, page: page)
    }

    /// The notice to show: the latest release, if it is newer than this copy.
    static func notice(latest: UpdateNotice?, current: String?) -> UpdateNotice? {
        guard let latest, let current, isNewer(latest.version, than: current) else { return nil }
        return latest
    }

    static func fetch(_ session: URLSession) async -> UpdateNotice? {
        var req = URLRequest(url: latestURL)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 8
        guard let (data, resp) = try? await session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return parse(data)
    }

    // MARK: - How this copy is upgraded

    static let caskCommand = "brew upgrade --cask barathanaslan/tailmon/tailmon-app"

    /// The upgrade command for the way this copy was installed: the Homebrew
    /// cask leaves its folder in the Caskroom. A copy built from source has
    /// no command; the menu offers the release page only.
    static func upgradeCommand(fileExists: (String) -> Bool = FileManager.default.fileExists) -> String? {
        let caskrooms = ["/opt/homebrew/Caskroom/tailmon-app", "/usr/local/Caskroom/tailmon-app"]
        return caskrooms.contains(where: fileExists) ? caskCommand : nil
    }

    // MARK: - The last answer (UserDefaults, three small values)

    private static let checkedAtKey = "update.checkedAt"
    private static let versionKey = "update.latestVersion"
    private static let pageKey = "update.latestPage"

    static func lastChecked(_ d: UserDefaults = .standard) -> Date? {
        d.object(forKey: checkedAtKey) as? Date
    }

    static func loadLatest(_ d: UserDefaults = .standard) -> UpdateNotice? {
        guard let v = d.string(forKey: versionKey), let p = d.string(forKey: pageKey),
              let page = URL(string: p) else { return nil }
        return UpdateNotice(version: v, page: page)
    }

    static func save(_ latest: UpdateNotice, at: Date, _ d: UserDefaults = .standard) {
        d.set(at, forKey: checkedAtKey)
        d.set(latest.version, forKey: versionKey)
        d.set(latest.page.absoluteString, forKey: pageKey)
    }

    /// Whether a request is due: none in the last day, and no failed one in
    /// the last hour.
    static func isDue(now: Date, lastChecked: Date?, lastAttempt: Date?) -> Bool {
        if let lastChecked, now.timeIntervalSince(lastChecked) < interval { return false }
        if let lastAttempt, now.timeIntervalSince(lastAttempt) < retryAfterFailure { return false }
        return true
    }
}
