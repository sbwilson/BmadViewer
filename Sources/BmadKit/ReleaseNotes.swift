import Foundation

/// A release as GitHub's Releases API describes it. GitHub Releases is the one
/// place notes get written, at tag time; the app only ever reads them.
public struct Release: Decodable, Sendable, Identifiable {
    public let id: Int
    public let tagName: String
    public let name: String?
    public let body: String?
    public let htmlURL: URL
    public let publishedAt: Date?
    public let draft: Bool
    public let prerelease: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, body, draft, prerelease
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case publishedAt = "published_at"
    }

    /// GitHub's own title, falling back to the tag.
    public var title: String { (name?.isEmpty == false ? name : nil) ?? tagName }
}

public enum ReleaseNotes {
    /// Decodes the API's array of releases, dropping drafts and ordering newest
    /// first: by version number, so `v0.10` outranks `v0.9`, then by publish date.
    public static func releases(from data: Data) throws -> [Release] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([Release].self, from: data)
            .filter { !$0.draft }
            .sorted { a, b in
                let c = compare(version(a.tagName) ?? [], version(b.tagName) ?? [])
                if c != 0 { return c > 0 }
                return (a.publishedAt ?? .distantPast) > (b.publishedAt ?? .distantPast)
            }
    }

    /// The numbers in a version as written: `v0.1`, `0.2-rc1` and a git-describe
    /// build string (`v0.1-5-gabc1234`) all parse to their dotted prefix.
    public static func version(_ written: String) -> [Int]? {
        let core = written.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "^v", with: "", options: .regularExpression)
            .prefix { $0.isNumber || $0 == "." }
        guard !core.isEmpty else { return nil }
        let parts = core.split(separator: ".").map { Int($0) }
        return parts.contains(nil) ? nil : parts.compactMap { $0 }
    }

    /// Version comparison padded with zeros: `[0, 2]` beats `[0, 1, 9]`.
    public static func compare(_ a: [Int], _ b: [Int]) -> Int {
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y ? 1 : -1 }
        }
        return 0
    }

    /// The releases as one document for the notes view: a heading and a caption
    /// per release, newest first, each caption marked against the running build.
    public static func notesMarkdown(_ releases: [Release], currentVersion: String?) -> String {
        let current = currentVersion.flatMap(version)
        return releases.map { release in
            var marks: [String] = []
            if let at = release.publishedAt { marks.append("Published \(day(at))") }
            if release.prerelease { marks.append("pre-release") }
            if let current {
                switch compare(version(release.tagName) ?? [], current) {
                case 0: marks.append("this version")
                case 1...: marks.append("newer than this build")
                default: break
                }
            }
            let joined = marks.joined(separator: " · ")
            let caption = marks.isEmpty ? "" : "*\(joined)*\n\n"
            return "## \(release.title)\n\n" + caption
                + (release.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }.joined(separator: "\n\n---\n\n")
    }

    /// `31 Oct 2026`, in UTC the way GitHub counts a release day.
    static func day(_ date: Date?) -> String {
        guard let date else { return "an undated release" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .gmt
        formatter.dateFormat = "d MMM yyyy"
        return formatter.string(from: date)
    }
}
