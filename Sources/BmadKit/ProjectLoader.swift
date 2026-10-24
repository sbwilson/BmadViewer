import Foundation

/// Assembles a `Project` from a folder on disk.
public enum ProjectLoader {
    public enum Failure: Error, LocalizedError {
        case notABmadProject(URL)

        public var errorDescription: String? {
            switch self {
            case .notABmadProject(let url):
                "No sprint-status.yaml or ticket tree found under \(url.path(percentEncoded: false))"
            }
        }
    }

    public static func load(root: URL) throws -> Project {
        let root = root.standardizedFileURL
        let paths = ConfigResolver.resolve(root: root)
        var warnings: [String] = []

        // A configured active initiative means a v7 ticket tree, even beside older v6 artifacts.
        if paths.activeInitiative != nil, let initiative = TicketTree.findInitiative(root: root, paths: paths) {
            return try TicketTree.load(root: root, initiative: initiative, paths: paths)
        }
        guard let statusFile = findStatusFile(root: root, paths: paths) else {
            if let initiative = TicketTree.findInitiative(root: root, paths: paths) {
                return try TicketTree.load(root: root, initiative: initiative, paths: paths)
            }
            throw Failure.notABmadProject(root)
        }

        let status = try SprintStatus.parse(String(contentsOf: statusFile, encoding: .utf8))
        let planning = paths.planning ?? statusFile.deletingLastPathComponent()
        let storyDir: URL = {
            if let loc = status.storyLocation {
                let u = loc.hasPrefix("/") ? URL(filePath: loc) : root.appending(path: loc)
                if FileManager.default.fileExists(atPath: u.path(percentEncoded: false)) { return u }
            }
            return paths.implementation ?? statusFile.deletingLastPathComponent()
        }()

        let epicsURL = existing(planning.appending(path: "epics.md"))
        let epicsDoc = epicsURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }.map(EpicsDocument.init)
        let buildOrderURL = existing(planning.appending(path: "build-order.md"))
        let queue = buildOrderURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }.map(BuildOrder.parse) ?? []
        let index = StoryFileIndex(directory: storyDir)

        var epics: [Epic] = []
        var epicIndex: [String: Int] = [:]
        func epicSlot(_ id: String) -> Int {
            if let i = epicIndex[id] { return i }
            epics.append(Epic(
                id: id,
                title: epicsDoc?.epicTitles[id] ?? "Epic \(id)",
                status: Status("unknown"),
                stories: []
            ))
            epicIndex[id] = epics.count - 1
            return epics.count - 1
        }

        for (key, value) in status.entries {
            switch SprintStatus.Key(key) {
            case .epic(let id):
                epics[epicSlot(id)].status = Status(value)
            case .retrospective(let id):
                epics[epicSlot(id)].retrospective = Status(value)
            case .story(let e, let s, let slug):
                let number = "\(e).\(s)"
                var story = Story(
                    id: key, number: number, epicID: e,
                    title: epicsDoc?.storyTitles[number] ?? humanise(slug),
                    status: Status(value)
                )
                if let doc = index.file(epic: e, story: s, slug: slug) {
                    story.documents.append(StoryDocument(label: "Story file", url: doc))
                    if let text = try? String(contentsOf: doc, encoding: .utf8) {
                        story.review = ReviewOrder.parse(text, document: doc, projectRoot: root)
                        story.frontMatter = FrontMatter.split(text).fields
                        if epicsDoc?.storyTitles[number] == nil, let t = story.frontMatter["title"] {
                            story.title = stripStoryPrefix(t)
                        }
                    }
                }
                if let excerpt = epicsDoc?.storySections[number] {
                    story.documents.append(StoryDocument(label: "Epic definition", markdown: excerpt, url: epicsURL))
                }
                epics[epicSlot(e)].stories.append(story)
            case .unrecognised:
                warnings.append("Unrecognised key in development_status: \(key)")
            }
        }

        let queuedNumbers = queue.flatMap(\.entries)
        for i in epics.indices {
            for j in epics[i].stories.indices {
                if let entry = queuedNumbers.first(where: { $0.storyNumber == epics[i].stories[j].number }) {
                    epics[i].stories[j].waitsOn = entry.waitsOn
                }
            }
        }

        let known = Set(epics.flatMap { $0.stories.map(\.number) })
        for section in queue {
            for entry in section.entries where !known.contains(entry.storyNumber) {
                warnings.append("\(section.heading): queued story \(entry.storyNumber) is not in sprint-status.yaml")
            }
        }

        var project = Project(
            root: root,
            name: status.project ?? root.lastPathComponent,
            layout: .sprintStatus,
            epics: epics,
            queue: queue,
            sources: .init(
                statusFile: statusFile, epicsFile: epicsURL, buildOrderFile: buildOrderURL,
                storyDirectory: storyDir, planningDirectory: planning
            ),
            warnings: warnings
        )
        project.documents = [buildOrderURL, epicsURL, statusFile].compactMap { $0 }

        // Retrospectives: each epic's `epic-<n>-retro-*.md` beside the stories.
        let storyFiles = ((try? FileManager.default.contentsOfDirectory(at: storyDir, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for i in project.epics.indices {
            let prefix = "epic-\(project.epics[i].id)-retro-"
            project.epics[i].documents += storyFiles.filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "md" }
        }
        let statusText = (try? String(contentsOf: statusFile, encoding: .utf8)) ?? ""
        project.retroActions = WorkItems.sprintActionItems(statusText, statusFile: statusFile, root: root)
        if project.retroActions.isEmpty {
            // No tracked action items: read them from the retrospectives themselves.
            for epic in project.epics {
                for doc in epic.documents where doc.lastPathComponent.contains("-retro-") {
                    if let text = try? String(contentsOf: doc, encoding: .utf8) {
                        project.retroActions += WorkItems.retrospectiveActions(text, source: doc, epic: epic.id)
                    }
                }
            }
        }
        loadDeferredWork(into: &project, directories: [paths.implementation, storyDir])
        return project
    }

    static func loadDeferredWork(into project: inout Project, directories: [URL?]) {
        for dir in directories.compactMap({ $0 }) {
            let url = dir.appending(path: "deferred-work.md")
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                project.deferredWork = WorkItems.deferredWork(text, source: url)
                project.deferredWorkFile = url
                return
            }
        }
    }

    static func findStatusFile(root: URL, paths: ConfigResolver.Paths) -> URL? {
        for dir in [paths.implementation, paths.output].compactMap({ $0 }) {
            if let u = existing(dir.appending(path: "sprint-status.yaml")) { return u }
        }
        return shallowSearch(root: root, name: "sprint-status.yaml", maxDepth: 4)
    }

    /// Breadth-first, skipping archives, build output and worktrees, so the live
    /// file wins over the copies those folders hold.
    static func shallowSearch(root: URL, name: String, maxDepth: Int) -> URL? {
        let skip: Set<String> = [".git", ".build", "build", "target", "node_modules", "archive", "worktrees", "DerivedData", ".claude"]
        var level = [root]
        for _ in 0...maxDepth {
            var next: [URL] = []
            for dir in level {
                let children = (try? FileManager.default.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
                )) ?? []
                for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    if child.lastPathComponent == name { return child }
                    let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                    if isDir, !skip.contains(child.lastPathComponent), !child.lastPathComponent.hasPrefix("DerivedData") {
                        next.append(child)
                    }
                }
            }
            level = next
        }
        return nil
    }

    static func existing(_ url: URL) -> URL? {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) ? url : nil
    }

    static func humanise(_ slug: String) -> String {
        let s = slug.replacingOccurrences(of: "-", with: " ")
        return s.prefix(1).uppercased() + s.dropFirst()
    }

    static func stripStoryPrefix(_ title: String) -> String {
        title.replacing(/^Story\s+[\w.-]+\s*[—–:-]\s*/, with: "")
    }
}

/// Maps a story to its document. Tracking keys are truncated (`…-diagnostics-spl`)
/// while file names are not (`spec-1-8-…-diagnostics-split.md`), so the match is on
/// the `<epic>-<story>-` number, with the slug only breaking ties.
struct StoryFileIndex {
    private var byNumber: [String: [URL]] = [:]

    init(directory: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "md" {
            let name = file.deletingPathExtension().lastPathComponent
            guard let m = name.wholeMatch(of: /(?:spec-|story-)?(\d+)-(\d+[a-z]?)-(.+)/) else { continue }
            byNumber["\(m.1)-\(m.2)", default: []].append(file)
        }
    }

    func file(epic: String, story: String, slug: String) -> URL? {
        guard let candidates = byNumber["\(epic)-\(story)"] else { return nil }
        return candidates.max { a, b in
            commonPrefix(a, slug) < commonPrefix(b, slug)
        }
    }

    private func commonPrefix(_ url: URL, _ slug: String) -> Int {
        let name = url.deletingPathExtension().lastPathComponent
            .replacing(/^(?:spec-|story-)?\d+-\d+[a-z]?-/, with: "")
        return zip(name, slug).prefix { $0 == $1 }.count
    }
}
