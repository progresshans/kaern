import Foundation

/// A .gitignore to start a repository with. Each one skips what that kind of project builds or
/// downloads, plus the files Finder leaves behind.
public enum IgnoreTemplate: String, CaseIterable, Sendable, Hashable {
    case none = "None"
    case macOS
    case node = "Node"
    case swift = "Swift"
    case xcode = "Xcode"
    case python = "Python"
    case go = "Go"
    case rust = "Rust"

    /// The line under the pop-up in the Create sheet.
    public var note: String {
        switch self {
        case .none: "Nothing is ignored"
        case .macOS: "Skips .DS_Store and other Finder files"
        case .node: "Skips node_modules/, logs and build output, plus macOS files"
        case .swift: "Skips .build/, .swiftpm/ and Xcode user data, plus macOS files"
        case .xcode: "Skips DerivedData/, build/ and xcuserdata, plus macOS files"
        case .python: "Skips __pycache__/, virtual environments and build output, plus macOS files"
        case .go: "Skips binaries and test output, plus macOS files"
        case .rust: "Skips target/, plus macOS files"
        }
    }

    /// The file's text (`nil` for None).
    public var contents: String? {
        guard self != .none else { return nil }
        var sections: [String] = []
        switch self {
        case .node:
            sections.append("""
            # Dependencies
            node_modules/
            .pnp
            .pnp.js
            .yarn/cache
            .yarn/install-state.gz

            # Build output
            dist/
            build/
            out/
            .next/
            .nuxt/
            .astro/
            .svelte-kit/
            .cache/
            coverage/

            # Logs
            logs/
            *.log
            npm-debug.log*
            yarn-debug.log*
            yarn-error.log*
            pnpm-debug.log*

            # Environment
            .env
            .env.*
            !.env.example
            """)
        case .swift:
            sections.append("""
            # Swift Package Manager
            .build/
            .swiftpm/
            Packages/
            *.xcodeproj/xcuserdata/
            *.xcworkspace/xcuserdata/

            # Xcode
            DerivedData/
            xcuserdata/
            *.xcscmblueprint
            *.xccheckout
            """)
        case .xcode:
            sections.append("""
            # Xcode
            build/
            DerivedData/
            xcuserdata/
            *.xcscmblueprint
            *.xccheckout
            *.moved-aside
            *.hmap
            *.ipa
            *.dSYM.zip
            *.dSYM
            """)
        case .python:
            sections.append("""
            # Byte-compiled files
            __pycache__/
            *.py[cod]
            *$py.class

            # Packaging
            build/
            dist/
            *.egg-info/
            .eggs/

            # Virtual environments
            .venv/
            venv/
            env/

            # Tools
            .pytest_cache/
            .mypy_cache/
            .ruff_cache/
            .coverage
            htmlcov/
            .ipynb_checkpoints/
            .env
            """)
        case .go:
            sections.append("""
            # Binaries
            *.exe
            *.exe~
            *.dll
            *.so
            *.dylib

            # Test output
            *.test
            *.out
            coverage.*

            # Workspaces
            go.work
            go.work.sum
            .env
            """)
        case .rust:
            sections.append("""
            # Build output
            target/
            debug/
            **/*.rs.bk
            *.pdb
            """)
        case .none, .macOS:
            break
        }
        sections.append("""
        # macOS
        .DS_Store
        .AppleDouble
        .LSOverride
        ._*
        .Spotlight-V100
        .Trashes
        """)
        return sections.joined(separator: "\n\n") + "\n"
    }
}

/// What's in a folder that isn't a repository yet: what kind of project it looks like, how many
/// files it has and which folders are generated (the empty state's chips, the Create sheet's
/// .gitignore pick).
public struct FolderSurvey: Sendable, Hashable {
    /// A folder a build or package manager fills ("node_modules/" with 1,842 files).
    public struct GeneratedFolder: Sendable, Hashable {
        public var name: String
        public var files: Int

        public init(name: String, files: Int) {
            self.name = name
            self.files = files
        }
    }

    /// "Astro site", "Swift package"… (`nil`: nothing recognized).
    public var kind: String?
    /// The file that told ("package.json").
    public var marker: String?
    public var template: IgnoreTemplate
    /// Files outside `.git` and the generated folders.
    public var files: Int
    public var bytes: Int64
    /// The count stopped at the limit.
    public var isCapped: Bool
    public var generated: [GeneratedFolder]

    public init(kind: String? = nil, marker: String? = nil, template: IgnoreTemplate = .macOS, files: Int = 0, bytes: Int64 = 0,
                isCapped: Bool = false, generated: [GeneratedFolder] = []) {
        self.kind = kind
        self.marker = marker
        self.template = template
        self.files = files
        self.bytes = bytes
        self.isCapped = isCapped
        self.generated = generated
    }

    /// Folders each kind of project generates, by template.
    static let generatedNames: [String: IgnoreTemplate] = [
        "node_modules": .node, ".next": .node, ".nuxt": .node, ".svelte-kit": .node, ".astro": .node,
        ".build": .swift, ".swiftpm": .swift, "DerivedData": .xcode,
        "__pycache__": .python, ".venv": .python, "venv": .python, ".pytest_cache": .python, ".mypy_cache": .python,
        "target": .rust,
    ]

    /// Looks at `folder` (counting at most `limit` files).
    public static func survey(_ folder: URL, limit: Int = 200_000) -> FolderSurvey {
        let fileManager = FileManager.default
        var survey = FolderSurvey()
        let top = (try? fileManager.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []
        (survey.kind, survey.marker, survey.template) = recognize(folder, top: top)

        var generated: [String: Int] = [:]
        var seen = 0
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey]
        guard let walker = fileManager.enumerator(at: folder, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else {
            return survey
        }
        while let url = walker.nextObject() as? URL {
            seen += 1
            if seen > limit {
                survey.isCapped = true
                break
            }
            let name = url.lastPathComponent
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                if name == ".git" {
                    walker.skipDescendants()
                    continue
                }
                if let template = generatedNames[name], template != .rust || survey.template == .rust {
                    let count = countFiles(in: url, limit: max(0, limit - seen))
                    seen += count
                    generated[name + "/", default: 0] += count
                    walker.skipDescendants()
                }
                continue
            }
            guard values?.isRegularFile == true, name != ".DS_Store" else { continue }
            survey.files += 1
            survey.bytes += Int64(values?.fileSize ?? 0)
        }
        survey.generated = generated.map { GeneratedFolder(name: $0.key, files: $0.value) }.sorted { $0.files > $1.files }
        if survey.kind == nil, let biggest = survey.generated.first, let template = generatedNames[String(biggest.name.dropLast())] {
            survey.template = template
        }
        return survey
    }

    private static func countFiles(in folder: URL, limit: Int) -> Int {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [],
                                                          errorHandler: { _, _ in true }) else { return 0 }
        var count = 0
        while let url = walker.nextObject() as? URL, count < limit {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true { count += 1 }
        }
        return count
    }

    /// What the top of the folder says the project is.
    static func recognize(_ folder: URL, top: [String]) -> (String?, String?, IgnoreTemplate) {
        let names = Set(top)
        if names.contains("package.json") {
            let data = FileManager.default.contents(atPath: folder.appending(path: "package.json").path(percentEncoded: false))
            return (nodeKind(data), "package.json", .node)
        }
        if names.contains("Package.swift") { return ("Swift package", "Package.swift", .swift) }
        if let project = top.first(where: { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }) {
            return ("Xcode project", project, .xcode)
        }
        if names.contains("Cargo.toml") { return ("Rust crate", "Cargo.toml", .rust) }
        if names.contains("go.mod") { return ("Go module", "go.mod", .go) }
        for marker in ["pyproject.toml", "requirements.txt", "setup.py", "Pipfile"] where names.contains(marker) {
            return ("Python project", marker, .python)
        }
        if names.contains("Gemfile") { return ("Ruby project", "Gemfile", .macOS) }
        return (nil, nil, .macOS)
    }

    /// "Astro site", "Next.js app"… from package.json's dependencies.
    static func nodeKind(_ data: Data?) -> String {
        guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "Node project" }
        var dependencies = Set<String>()
        for key in ["dependencies", "devDependencies"] {
            if let list = json[key] as? [String: Any] { dependencies.formUnion(list.keys) }
        }
        let kinds: [(String, String)] = [
            ("astro", "Astro site"), ("next", "Next.js app"), ("nuxt", "Nuxt app"), ("@sveltejs/kit", "SvelteKit app"),
            ("@remix-run/react", "Remix app"), ("gatsby", "Gatsby site"), ("electron", "Electron app"), ("@angular/core", "Angular app"),
            ("vue", "Vue app"), ("svelte", "Svelte app"), ("react", "React app"), ("vite", "Vite app"), ("express", "Node server"),
        ]
        return kinds.first { dependencies.contains($0.0) }?.1 ?? "Node project"
    }
}
