import Foundation

/// A small regex highlighter: enough to read code at a glance, not a parser.
/// It returns token ranges; the app maps them to colours.
public enum Syntax {
    public enum Token: Sendable, Hashable {
        case comment, string, number, keyword, type, key, heading, tag
    }

    public struct Language: Sendable {
        public let name: String
        var lineComments: [String] = []
        var blockComments: [(String, String)] = []
        var quotes: [String] = ["\"", "'"]
        var tripleQuotes = false
        var keywords: Set<String> = []
        var caseInsensitiveKeywords = false
        var capitalisedTypes = false
        var keyStyle: KeyStyle = .none
        var markdown = false
        var markup = false

        enum KeyStyle: Sendable { case none, yaml, toml, json }
    }

    public static func language(for url: URL) -> Language {
        let ext = url.pathExtension.lowercased()
        let name = url.lastPathComponent.lowercased()
        switch ext {
        case "swift":
            return Language(name: "Swift", lineComments: ["//"], blockComments: [("/*", "*/")], quotes: ["\""], tripleQuotes: true,
                            keywords: swift, capitalisedTypes: true)
        case "rs":
            return Language(name: "Rust", lineComments: ["//"], blockComments: [("/*", "*/")], quotes: ["\""],
                            keywords: rust, capitalisedTypes: true)
        case "ts", "tsx", "js", "jsx", "mjs", "cjs", "mts", "cts":
            return Language(name: "TypeScript", lineComments: ["//"], blockComments: [("/*", "*/")], quotes: ["\"", "'", "`"],
                            keywords: typescript, capitalisedTypes: true)
        case "py":
            return Language(name: "Python", lineComments: ["#"], tripleQuotes: true, keywords: python, capitalisedTypes: true)
        case "sh", "bash", "zsh", "fish":
            return Language(name: "Shell", lineComments: ["#"], keywords: shell)
        case "go":
            return Language(name: "Go", lineComments: ["//"], blockComments: [("/*", "*/")], quotes: ["\"", "'", "`"],
                            keywords: go, capitalisedTypes: true)
        case "c", "h", "cc", "cpp", "hpp", "m", "mm":
            return Language(name: "C", lineComments: ["//"], blockComments: [("/*", "*/")], keywords: c, capitalisedTypes: true)
        case "java", "kt", "kts", "scala", "cs":
            return Language(name: "JVM", lineComments: ["//"], blockComments: [("/*", "*/")], tripleQuotes: true,
                            keywords: jvm, capitalisedTypes: true)
        case "sql":
            return Language(name: "SQL", lineComments: ["--"], blockComments: [("/*", "*/")], keywords: sql, caseInsensitiveKeywords: true)
        case "yaml", "yml":
            return Language(name: "YAML", lineComments: ["#"], keywords: literals, keyStyle: .yaml)
        case "toml":
            return Language(name: "TOML", lineComments: ["#"], tripleQuotes: true, keywords: literals, keyStyle: .toml)
        case "json", "jsonc":
            return Language(name: "JSON", lineComments: ["//"], quotes: ["\""], keywords: literals, keyStyle: .json)
        case "md", "markdown":
            return Language(name: "Markdown", quotes: [], markdown: true)
        case "html", "htm", "xml", "plist", "svg", "xib", "storyboard":
            return Language(name: "Markup", blockComments: [("<!--", "-->")], quotes: ["\""], markup: true)
        case "css", "scss":
            return Language(name: "CSS", blockComments: [("/*", "*/")], keywords: [])
        case "ftl":
            return Language(name: "Fluent", lineComments: ["#"], quotes: ["\""])
        default:
            if name == "dockerfile" || name == "makefile" { return Language(name: "Shell", lineComments: ["#"], keywords: shell) }
            return Language(name: "Text", quotes: [])
        }
    }

    public static func tokens(_ text: String, _ lang: Language) -> [(range: NSRange, token: Token)] {
        var out: [(NSRange, Token)] = []
        let ns = text as NSString
        let all = NSRange(location: 0, length: ns.length)

        func run(_ pattern: String, _ token: Token, options: NSRegularExpression.Options = [], group: Int = 0) {
            guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return }
            re.enumerateMatches(in: text, range: all) { m, _, _ in
                if let r = m?.range(at: group), r.location != NSNotFound { out.append((r, token)) }
            }
        }

        if lang.markdown {
            run("^ {0,3}#{1,6}[ \\t].*$", .heading, options: .anchorsMatchLines)
            run("^---$[\\s\\S]*?^---$", .comment, options: .anchorsMatchLines)       // front matter
            run("^```[\\s\\S]*?^```", .string, options: .anchorsMatchLines)
            run("`[^`\\n]+`", .string)
            run("\\[[^\\]\\n]*\\]\\([^)\\n]*\\)", .keyword)
            run("\\*\\*[^*\\n]+\\*\\*", .type)
            return out
        }
        if lang.markup {
            run("</?[A-Za-z][^>]*>", .tag)
            run("\"[^\"\\n]*\"", .string)
            run("<!--[\\s\\S]*?-->", .comment)
            return out
        }

        // One alternation, so a quote inside a comment is not a string and vice versa.
        var comments: [String] = lang.blockComments.map { NSRegularExpression.escapedPattern(for: $0.0) + "[\\s\\S]*?" + NSRegularExpression.escapedPattern(for: $0.1) }
        comments += lang.lineComments.map { NSRegularExpression.escapedPattern(for: $0) + "[^\\n]*" }
        var strings: [String] = []
        if lang.tripleQuotes { strings += ["\"\"\"[\\s\\S]*?\"\"\"", "'''[\\s\\S]*?'''"] }
        strings += lang.quotes.map { q in
            let e = NSRegularExpression.escapedPattern(for: q)
            return q == "`" ? "`(?:\\\\.|[^`\\\\])*`" : "\(e)(?:\\\\.|[^\(e)\\\\\\n])*\(e)"
        }
        let never = "(?!x)x"
        let commentGroup: String = comments.isEmpty ? never : comments.joined(separator: "|")
        let stringGroup: String = strings.isEmpty ? never : strings.joined(separator: "|")
        let numberGroup = "\\b(?:0[xX][0-9a-fA-F_]+|\\d[\\d_]*(?:\\.\\d+)?(?:[eE][+-]?\\d+)?)\\b"
        let wordGroup = "\\b[A-Za-z_][A-Za-z0-9_]*\\b"
        let pattern = [commentGroup, stringGroup, numberGroup, wordGroup].map { "(\($0))" }.joined(separator: "|")
        guard let re = try? NSRegularExpression(pattern: pattern) else { return out }
        re.enumerateMatches(in: text, range: all) { m, _, _ in
            guard let m else { return }
            if m.range(at: 1).location != NSNotFound { out.append((m.range(at: 1), .comment)) }
            else if m.range(at: 2).location != NSNotFound { out.append((m.range(at: 2), .string)) }
            else if m.range(at: 3).location != NSNotFound { out.append((m.range(at: 3), .number)) }
            else if m.range(at: 4).location != NSNotFound {
                let r = m.range(at: 4)
                let word = ns.substring(with: r)
                if lang.keywords.contains(lang.caseInsensitiveKeywords ? word.lowercased() : word) {
                    out.append((r, .keyword))
                } else if lang.capitalisedTypes, let f = word.unicodeScalars.first, CharacterSet.uppercaseLetters.contains(f) {
                    out.append((r, .type))
                }
            }
        }

        // Keys and table headers go on top of what the main pass found.
        switch lang.keyStyle {
        case .yaml: run("^[ \\t-]*([A-Za-z0-9_.\"'/-]+)(?=[ \\t]*:(?:[ \\t]|$))", .key, options: .anchorsMatchLines, group: 1)
        case .toml:
            run("^[ \\t]*\\[\\[?[^\\]\\n]+\\]\\]?", .heading, options: .anchorsMatchLines)
            run("^[ \\t]*([A-Za-z0-9_.\"-]+)[ \\t]*(?==)", .key, options: .anchorsMatchLines, group: 1)
        case .json: run("(\"(?:\\\\.|[^\"\\\\])*\")(?=\\s*:)", .key, group: 1)
        case .none: break
        }
        return out
    }

    static let literals: Set<String> = ["true", "false", "null", "nil", "yes", "no", "on", "off", "inf", "nan"]
    static let swift: Set<String> = ["actor", "any", "as", "associatedtype", "async", "await", "break", "case", "catch", "class", "continue", "default", "defer", "deinit", "do", "else", "enum", "extension", "fallthrough", "false", "fileprivate", "for", "func", "guard", "if", "import", "in", "init", "inout", "internal", "is", "let", "nil", "nonisolated", "open", "operator", "private", "protocol", "public", "repeat", "rethrows", "return", "self", "Self", "some", "static", "struct", "subscript", "super", "switch", "throw", "throws", "true", "try", "typealias", "var", "where", "while", "mutating", "override", "final", "weak", "lazy", "consuming", "borrowing", "sending"]
    static let rust: Set<String> = ["as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern", "false", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return", "self", "Self", "static", "struct", "super", "trait", "true", "type", "unsafe", "use", "where", "while", "macro_rules"]
    static let typescript: Set<String> = ["abstract", "as", "async", "await", "break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete", "do", "else", "enum", "export", "extends", "false", "finally", "for", "from", "function", "if", "implements", "import", "in", "instanceof", "interface", "let", "new", "null", "of", "private", "protected", "public", "readonly", "return", "static", "super", "switch", "this", "throw", "true", "try", "type", "typeof", "undefined", "var", "void", "while", "yield", "satisfies", "keyof"]
    static let python: Set<String> = ["False", "None", "True", "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif", "else", "except", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "nonlocal", "not", "or", "pass", "raise", "return", "try", "while", "with", "yield", "match", "case", "self"]
    static let shell: Set<String> = ["if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac", "in", "function", "return", "local", "export", "set", "unset", "echo", "exit", "source", "readonly", "true", "false"]
    static let go: Set<String> = ["break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "for", "func", "go", "goto", "if", "import", "interface", "map", "package", "range", "return", "select", "struct", "switch", "type", "var", "true", "false", "nil"]
    static let c: Set<String> = ["auto", "break", "case", "char", "const", "continue", "default", "do", "double", "else", "enum", "extern", "float", "for", "goto", "if", "inline", "int", "long", "register", "return", "short", "signed", "sizeof", "static", "struct", "switch", "typedef", "union", "unsigned", "void", "volatile", "while", "class", "namespace", "template", "public", "private", "protected", "virtual", "nullptr", "true", "false", "nil", "self", "YES", "NO", "@interface", "@implementation", "@end"]
    static let jvm: Set<String> = ["abstract", "class", "val", "var", "fun", "def", "object", "package", "import", "public", "private", "protected", "internal", "static", "final", "override", "return", "if", "else", "when", "for", "while", "do", "try", "catch", "finally", "throw", "new", "this", "super", "null", "true", "false", "interface", "enum", "extends", "implements", "void", "int", "long", "boolean", "data", "sealed", "suspend", "namespace", "using"]
    static let sql: Set<String> = ["select", "from", "where", "insert", "into", "values", "update", "set", "delete", "create", "table", "index", "view", "trigger", "drop", "alter", "add", "column", "primary", "key", "foreign", "references", "not", "null", "unique", "default", "check", "and", "or", "in", "is", "join", "left", "right", "inner", "outer", "on", "as", "group", "by", "order", "having", "limit", "offset", "union", "all", "distinct", "case", "when", "then", "else", "end", "begin", "commit", "rollback", "transaction", "integer", "text", "real", "blob", "with", "exists", "if", "virtual", "using", "returning"]
}
