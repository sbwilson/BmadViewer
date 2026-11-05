import Foundation

/// The `bmad-build` / `bmad-build-auto` invocation that hands a story off, the way
/// upstream dispatches one: a ticket-tree ticket is named `ticket <ref>` (the
/// `<epic id>.<entry id>` that `tickets.py find` reads, or the ticket file for a
/// backlog ticket, which has no ref), and a sprint-status story by the path of its
/// spec file, which Build resumes from its front-matter status.
public enum RunCommand {
    /// The line to paste into a fresh agent chat; nil when the story is not Build's
    /// to take: finished, blocked, still waiting on something, or with no argument
    /// Build could resolve.
    public static func command(for story: Story, in project: Project, auto: Bool = false) -> String? {
        guard !story.status.isTerminal, story.status.kind != .blocked, story.waitsOn.isEmpty else { return nil }
        guard let argument = argument(for: story, in: project) else { return nil }
        return "/\(auto ? "bmad-build-auto" : "bmad-build") \(argument)"
    }

    static func argument(for story: Story, in project: Project) -> String? {
        if project.layout == .ticketTree {
            // Build never pulls a ticket, so it names the tree entry; the backlog has
            // no `<epic>.<entry>` ref, and a ticket file by path is an accepted shape.
            if story.epicID == "backlog" {
                return story.primaryFile.map { "ticket \(relative($0, in: project))" }
            }
            return "ticket \(story.number)"
        }
        // v6: Build resumes from the spec file's status, so the file is the argument.
        guard let file = story.documents.first(where: { $0.label == "Story file" })?.url else { return nil }
        return relative(file, in: project)
    }

    /// A project-root-relative path — an agent chat starts at the root — quoted
    /// when it holds spaces.
    static func relative(_ url: URL, in project: Project) -> String {
        let path = url.path(percentEncoded: false)
        var root = project.root.path(percentEncoded: false)
        // A folder URL picked in a panel keeps its trailing slash.
        while root.hasSuffix("/"), root.count > 1 { root.removeLast() }
        let rel = path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : path
        return rel.contains(" ") ? "\"\(rel)\"" : rel
    }
}
