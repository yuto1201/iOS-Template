import Foundation

struct TemplateManifest: Codable {
    let schemaVersion: Int
    let source: SourceIdentity
    let renamePaths: [String]
    let liveContentPaths: [String]
}

struct SourceIdentity: Codable {
    let project: String
    let module: String
    let bundleId: String
}

struct AppIdentity: Codable {
    let displayName: String
    let moduleName: String
    let appSlug: String
    let bundleId: String
}

enum Command {
    case validate(manifestPath: String, identity: AppIdentity)
    case apply(rootPath: String, manifestPath: String, identity: AppIdentity)
}

enum BootstrapError: Error {
    case usage
    case unreadableManifest
    case unsupportedManifest
    case invalidIdentity
    case invalidRoot
    case invalidPath
    case destinationCollision
    case missingAnchor
    case malformedProject
    case writeFailed

    var message: String {
        switch self {
        case .usage:
            return "invalid command usage"
        case .unreadableManifest:
            return "unable to read manifest"
        case .unsupportedManifest:
            return "unsupported manifest"
        case .invalidIdentity:
            return "invalid app identity"
        case .invalidRoot:
            return "invalid staging root"
        case .invalidPath:
            return "invalid manifest path"
        case .destinationCollision:
            return "destination path collision"
        case .missingAnchor:
            return "required transformation anchor is missing"
        case .malformedProject:
            return "project configuration is malformed"
        case .writeFailed:
            return "unable to write transformed content"
        }
    }
}

let swiftKeywords: Set<String> = [
    "associatedtype", "async", "await", "break", "case", "catch", "class", "continue",
    "default", "defer", "deinit", "do", "dynamic", "each", "else", "enum", "extension",
    "fallthrough", "fileprivate", "final", "for", "func", "get", "guard", "if", "import",
    "in", "indirect", "infix", "init", "inout", "internal", "is", "isolated", "lazy", "let",
    "macro", "mutating", "nil", "nonisolated", "open", "operator", "optional", "override",
    "package", "postfix", "precedencegroup", "prefix", "private", "protocol", "public", "repeat",
    "required", "rethrows", "return", "self", "Self", "set", "some", "static", "struct",
    "subscript", "super", "switch", "throws", "throw", "try", "typealias", "unowned", "var",
    "weak", "where", "while", "willSet", "didSet", "actor", "any", "borrowing", "consuming",
    "distributed", "nonmutating", "sending"
]

func matches(_ value: String, pattern: String) -> Bool {
    guard let expression = try? NSRegularExpression(pattern: pattern) else {
        return false
    }
    let range = NSRange(value.startIndex..<value.endIndex, in: value)
    return expression.firstMatch(in: value, range: range)?.range == range
}

func parseCommand(arguments: [String]) throws -> Command {
    guard let action = arguments.first,
          action == "validate" || action == "apply" else {
        throw BootstrapError.usage
    }

    let values = Array(arguments.dropFirst())
    let expectedCount = action == "apply" ? 12 : 10
    guard values.count == expectedCount else {
        throw BootstrapError.usage
    }

    var options: [String: String] = [:]
    let allowedFlags = action == "apply"
        ? ["--root", "--manifest", "--display-name", "--module-name", "--app-slug", "--bundle-id"]
        : ["--manifest", "--display-name", "--module-name", "--app-slug", "--bundle-id"]
    var index = 0
    while index < values.count {
        let flag = values[index]
        let value = values[index + 1]
        guard allowedFlags.contains(flag),
              options[flag] == nil else {
            throw BootstrapError.usage
        }
        options[flag] = value
        index += 2
    }

    guard let manifestPath = options["--manifest"],
          let displayName = options["--display-name"],
          let moduleName = options["--module-name"],
          let appSlug = options["--app-slug"],
          let bundleId = options["--bundle-id"] else {
        throw BootstrapError.usage
    }

    let identity = AppIdentity(
        displayName: displayName,
        moduleName: moduleName,
        appSlug: appSlug,
        bundleId: bundleId
    )

    if action == "validate" {
        return .validate(manifestPath: manifestPath, identity: identity)
    }

    guard let rootPath = options["--root"] else {
        throw BootstrapError.usage
    }
    return .apply(rootPath: rootPath, manifestPath: manifestPath, identity: identity)
}

func readManifest(at path: String) throws -> TemplateManifest {
    guard let data = FileManager.default.contents(atPath: path),
          let manifest = try? JSONDecoder().decode(TemplateManifest.self, from: data) else {
        throw BootstrapError.unreadableManifest
    }
    guard manifest.schemaVersion == 1,
          !manifest.source.project.isEmpty,
          !manifest.source.module.isEmpty,
          !manifest.source.bundleId.isEmpty else {
        throw BootstrapError.unsupportedManifest
    }
    return manifest
}

func validatedIdentity(_ identity: AppIdentity, manifest: TemplateManifest) throws -> AppIdentity {
    guard !identity.displayName.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
        throw BootstrapError.invalidIdentity
    }

    let normalized = AppIdentity(
        displayName: identity.displayName.trimmingCharacters(in: .whitespaces),
        moduleName: identity.moduleName,
        appSlug: identity.appSlug,
        bundleId: identity.bundleId
    )

    guard (1...30).contains(normalized.displayName.count),
          !normalized.displayName.contains("/"),
          matches(normalized.moduleName, pattern: "^[A-Za-z][A-Za-z0-9]{1,49}$"),
          !swiftKeywords.contains(normalized.moduleName),
          normalized.moduleName != manifest.source.module,
          matches(normalized.appSlug, pattern: "^[a-z0-9]+(?:-[a-z0-9]+)*$"),
          normalized.appSlug.count <= 50,
          matches(normalized.bundleId, pattern: "^[A-Za-z0-9][A-Za-z0-9-]{0,62}(?:\\.[A-Za-z0-9][A-Za-z0-9-]{0,62})+$"),
          normalized.bundleId.count <= 255 else {
        throw BootstrapError.invalidIdentity
    }

    return normalized
}

struct ResultIdentity: Codable {
    let schemaVersion: Int
    let sourceIdentityVersion: Int
    let displayName: String
    let moduleName: String
    let appSlug: String
    let bundleId: String
}

struct ApplyResult: Codable {
    let status: String
    let resultRecordPath: String
    let moduleName: String
    let appSlug: String
    let bundleId: String
}

struct PathRename {
    let source: String
    let destination: String
    let xcodeProject: Bool
}

func countOccurrences(of needle: String, in text: String) -> Int {
    guard !needle.isEmpty else { return 0 }
    return text.components(separatedBy: needle).count - 1
}

func replaceExactly(_ old: String, with new: String, in path: URL, minimumCount: Int) throws {
    guard let content = try? String(contentsOf: path, encoding: .utf8),
          countOccurrences(of: old, in: content) >= minimumCount else {
        throw BootstrapError.missingAnchor
    }
    do {
        try content.replacingOccurrences(of: old, with: new).write(to: path, atomically: true, encoding: .utf8)
    } catch {
        throw BootstrapError.writeFailed
    }
}

func insertDisplayName(_ displayName: String, bundleID: String, inPBXProj path: URL) throws {
    guard let content = try? String(contentsOf: path, encoding: .utf8) else {
        throw BootstrapError.missingAnchor
    }

    let anchor = "\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = \(bundleID);\n\t\t\t\tPRODUCT_NAME"
    guard countOccurrences(of: anchor, in: content) == 2 else {
        throw BootstrapError.malformedProject
    }

    let escapedDisplayName = displayName
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    let replacement = "\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = \(bundleID);\n\t\t\t\tINFOPLIST_KEY_CFBundleDisplayName = \"\(escapedDisplayName)\";\n\t\t\t\tPRODUCT_NAME"
    do {
        try content.replacingOccurrences(of: anchor, with: replacement).write(to: path, atomically: true, encoding: .utf8)
    } catch {
        throw BootstrapError.writeFailed
    }
}

func writeIdentity(_ identity: AppIdentity, to path: URL) throws {
    let record = ResultIdentity(
        schemaVersion: 1,
        sourceIdentityVersion: 1,
        displayName: identity.displayName,
        moduleName: identity.moduleName,
        appSlug: identity.appSlug,
        bundleId: identity.bundleId
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    do {
        try encoder.encode(record).write(to: path)
    } catch {
        throw BootstrapError.writeFailed
    }
}

func isSymbolicLink(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
}

func safePath(_ relativePath: String, under root: URL) throws -> URL {
    guard !relativePath.isEmpty,
          !relativePath.hasPrefix("/"),
          !relativePath.split(separator: "/").contains("..") else {
        throw BootstrapError.invalidPath
    }
    let resolved = root.appendingPathComponent(relativePath).standardizedFileURL
    let rootPath = root.path.hasSuffix("/") ? String(root.path.dropLast()) : root.path
    guard resolved.path.hasPrefix(rootPath + "/") else {
        throw BootstrapError.invalidPath
    }
    return resolved
}

func requireRegularItem(at url: URL, under root: URL) throws {
    var current = url
    while true {
        if isSymbolicLink(current) {
            throw BootstrapError.invalidPath
        }
        if current.path == root.path { break }
        current.deleteLastPathComponent()
    }
    guard FileManager.default.fileExists(atPath: url.path) else {
        throw BootstrapError.invalidPath
    }
}

func resolvedPathRenames(manifest: TemplateManifest, identity: AppIdentity) throws -> [PathRename] {
    let source = manifest.source.module
    let expected = Set([
        "\(source).xcodeproj/xcshareddata/xcschemes/\(source).xcscheme",
        "\(source).xcodeproj",
        "\(source)/\(source)App.swift",
        "\(source)Tests/\(source)Tests.swift",
        "\(source)UITests/\(source)UITests.swift",
        source,
        "\(source)Tests",
        "\(source)UITests",
    ])
    guard manifest.renamePaths.count == expected.count,
          Set(manifest.renamePaths) == expected else {
        throw BootstrapError.unsupportedManifest
    }

    return [
        PathRename(
            source: "\(source).xcodeproj/xcshareddata/xcschemes/\(source).xcscheme",
            destination: "\(source).xcodeproj/xcshareddata/xcschemes/\(identity.moduleName).xcscheme",
            xcodeProject: false
        ),
        PathRename(
            source: "\(source)/\(source)App.swift",
            destination: "\(source)/\(identity.moduleName)App.swift",
            xcodeProject: false
        ),
        PathRename(
            source: "\(source)Tests/\(source)Tests.swift",
            destination: "\(source)Tests/\(identity.moduleName)Tests.swift",
            xcodeProject: false
        ),
        PathRename(
            source: "\(source)UITests/\(source)UITests.swift",
            destination: "\(source)UITests/\(identity.moduleName)UITests.swift",
            xcodeProject: false
        ),
        PathRename(source: source, destination: identity.moduleName, xcodeProject: false),
        PathRename(source: "\(source)Tests", destination: "\(identity.moduleName)Tests", xcodeProject: false),
        PathRename(source: "\(source)UITests", destination: "\(identity.moduleName)UITests", xcodeProject: false),
        PathRename(source: "\(source).xcodeproj", destination: "\(identity.moduleName).xcodeproj", xcodeProject: true),
    ]
}

func replaceOwnershipBundleID(_ bundleID: String, in path: URL) throws {
    guard let content = try? String(contentsOf: path, encoding: .utf8) else {
        throw BootstrapError.missingAnchor
    }
    let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
    var inAppStore = false
    var replacements = 0
    let transformed = lines.map { line -> String in
        if line == "appStore:" {
            inAppStore = true
            return String(line)
        }
        if !line.hasPrefix(" ") && !line.isEmpty {
            inAppStore = false
        }
        if inAppStore && line.hasPrefix("  bundleId:") {
            replacements += 1
            return "  bundleId: \(bundleID)"
        }
        return String(line)
    }.joined(separator: "\n")
    guard replacements == 1 else {
        throw BootstrapError.missingAnchor
    }
    do {
        try transformed.write(to: path, atomically: true, encoding: .utf8)
    } catch {
        throw BootstrapError.writeFailed
    }
}

func replaceFirstAgentContractHeading(_ displayName: String, in path: URL) throws {
    let heading = "# iOS-Template agent contract"
    guard let content = try? String(contentsOf: path, encoding: .utf8),
          let range = content.range(of: heading) else {
        throw BootstrapError.missingAnchor
    }
    let transformed = content.replacingCharacters(in: range, with: "# \(displayName) agent contract")
    do {
        try transformed.write(to: path, atomically: true, encoding: .utf8)
    } catch {
        throw BootstrapError.writeFailed
    }
}

func transformContent(root: URL, manifest: TemplateManifest, identity: AppIdentity) throws {
    let livePaths = Set(manifest.liveContentPaths)
    guard livePaths.count == manifest.liveContentPaths.count,
          livePaths.contains("\(manifest.source.project).xcodeproj/project.pbxproj"),
          livePaths.contains("\(manifest.source.project).xcodeproj/xcshareddata/xcschemes/\(manifest.source.module).xcscheme"),
          livePaths.contains("\(manifest.source.module)/\(manifest.source.module)App.swift"),
          livePaths.contains("\(manifest.source.module)/ContentView.swift"),
          livePaths.contains("\(manifest.source.module)/Localizable.xcstrings"),
          livePaths.contains("\(manifest.source.module)Tests/\(manifest.source.module)Tests.swift"),
          livePaths.contains("\(manifest.source.module)UITests/\(manifest.source.module)UITests.swift"),
          livePaths.contains("AGENTS.md"),
          livePaths.contains("Config/ownership.yml"),
          livePaths.contains("docs/security.md") else {
        throw BootstrapError.unsupportedManifest
    }

    for livePath in manifest.liveContentPaths {
        try requireRegularItem(at: safePath(livePath, under: root), under: root)
    }

    let pbxproj = try safePath("\(manifest.source.project).xcodeproj/project.pbxproj", under: root)
    try replaceExactly("\(manifest.source.bundleId)UITests", with: "\(identity.bundleId)UITests", in: pbxproj, minimumCount: 2)
    try replaceExactly("\(manifest.source.bundleId)Tests", with: "\(identity.bundleId)Tests", in: pbxproj, minimumCount: 2)
    try replaceExactly(manifest.source.bundleId, with: identity.bundleId, in: pbxproj, minimumCount: 2)

    let moduleContentPaths = [
        "\(manifest.source.project).xcodeproj/project.pbxproj",
        "\(manifest.source.project).xcodeproj/xcshareddata/xcschemes/\(manifest.source.module).xcscheme",
        "\(manifest.source.module)/\(manifest.source.module)App.swift",
        "\(manifest.source.module)/ContentView.swift",
        "\(manifest.source.module)Tests/\(manifest.source.module)Tests.swift",
        "\(manifest.source.module)UITests/\(manifest.source.module)UITests.swift",
        "README.md",
        "specs/architecture.md",
        "docs/verification.md",
        "docs/agent-contracts/review-packet.md",
    ]
    for livePath in moduleContentPaths {
        guard livePaths.contains(livePath) else {
            throw BootstrapError.unsupportedManifest
        }
        try replaceExactly(manifest.source.module, with: identity.moduleName, in: try safePath(livePath, under: root), minimumCount: 1)
    }

    let appSource = try safePath("\(manifest.source.module)/ContentView.swift", under: root)
    let localization = try safePath("\(manifest.source.module)/Localizable.xcstrings", under: root)
    let unitTests = try safePath("\(manifest.source.module)Tests/\(manifest.source.module)Tests.swift", under: root)
    let uiTests = try safePath("\(manifest.source.module)UITests/\(manifest.source.module)UITests.swift", under: root)
    try replaceExactly("template.welcome-title", with: "\(identity.appSlug).welcome-title", in: appSource, minimumCount: 1)
    try replaceExactly("template.welcome", with: "\(identity.appSlug).welcome", in: appSource, minimumCount: 1)
    try replaceExactly("template.welcome", with: "\(identity.appSlug).welcome", in: localization, minimumCount: 1)
    try replaceExactly("template.welcome", with: "\(identity.appSlug).welcome", in: unitTests, minimumCount: 2)
    try replaceExactly("template.welcome-title", with: "\(identity.appSlug).welcome-title", in: uiTests, minimumCount: 1)

    let security = try safePath("docs/security.md", under: root)
    try replaceExactly("template-app", with: identity.appSlug, in: security, minimumCount: 3)
    try replaceOwnershipBundleID(identity.bundleId, in: try safePath("Config/ownership.yml", under: root))
    try replaceFirstAgentContractHeading(identity.displayName, in: try safePath("AGENTS.md", under: root))
    try insertDisplayName(identity.displayName, bundleID: identity.bundleId, inPBXProj: pbxproj)
}

func renamePaths(root: URL, manifest: TemplateManifest, identity: AppIdentity) throws {
    let renames = try resolvedPathRenames(manifest: manifest, identity: identity)
    var destinations = Set<String>()
    for rename in renames {
        let source = try safePath(rename.source, under: root)
        let destination = try safePath(rename.destination, under: root)
        try requireRegularItem(at: source, under: root)
        guard destinations.insert(destination.path).inserted,
              !FileManager.default.fileExists(atPath: destination.path) else {
            throw BootstrapError.destinationCollision
        }
    }

    let ordered = renames.sorted {
        if $0.xcodeProject != $1.xcodeProject { return !$0.xcodeProject }
        let leftDepth = $0.source.split(separator: "/").count
        let rightDepth = $1.source.split(separator: "/").count
        return leftDepth > rightDepth
    }
    for rename in ordered {
        let source = try safePath(rename.source, under: root)
        let destination = try safePath(rename.destination, under: root)
        do {
            try FileManager.default.moveItem(at: source, to: destination)
        } catch {
            throw BootstrapError.writeFailed
        }
    }
}

func transformedLivePath(_ path: String, manifest: TemplateManifest, identity: AppIdentity) -> String {
    path
        .replacingOccurrences(of: "\(manifest.source.module).xcodeproj", with: "\(identity.moduleName).xcodeproj")
        .replacingOccurrences(of: "\(manifest.source.module)UITests", with: "\(identity.moduleName)UITests")
        .replacingOccurrences(of: "\(manifest.source.module)Tests", with: "\(identity.moduleName)Tests")
        .replacingOccurrences(of: manifest.source.module, with: identity.moduleName)
}

func auditResiduals(root: URL, manifest: TemplateManifest, identity: AppIdentity) throws {
    for path in manifest.liveContentPaths {
        let transformed = transformedLivePath(path, manifest: manifest, identity: identity)
        let file = try safePath(transformed, under: root)
        guard let content = try? String(contentsOf: file, encoding: .utf8),
              !content.contains(manifest.source.module) else {
            throw BootstrapError.missingAnchor
        }
    }
}

func apply(rootPath: String, manifestPath: String, identity: AppIdentity) throws -> ApplyResult {
    guard rootPath.hasPrefix("/") else {
        throw BootstrapError.invalidRoot
    }
    let root = URL(fileURLWithPath: rootPath).standardizedFileURL
    guard !isSymbolicLink(root),
          FileManager.default.fileExists(atPath: root.path) else {
        throw BootstrapError.invalidRoot
    }
    let manifestURL = URL(fileURLWithPath: manifestPath).standardizedFileURL
    let normalizedRootPath = root.path.hasSuffix("/") ? String(root.path.dropLast()) : root.path
    guard manifestURL.path.hasPrefix(normalizedRootPath + "/"),
          !isSymbolicLink(manifestURL) else {
        throw BootstrapError.invalidPath
    }

    let manifest = try readManifest(at: manifestURL.path)
    let validated = try validatedIdentity(identity, manifest: manifest)
    try transformContent(root: root, manifest: manifest, identity: validated)
    try renamePaths(root: root, manifest: manifest, identity: validated)
    try writeIdentity(validated, to: try safePath("Config/app-identity.json", under: root))
    try auditResiduals(root: root, manifest: manifest, identity: validated)
    return ApplyResult(
        status: "applied",
        resultRecordPath: "Config/app-identity.json",
        moduleName: validated.moduleName,
        appSlug: validated.appSlug,
        bundleId: validated.bundleId
    )
}

func main() throws {
    let command = try parseCommand(arguments: Array(CommandLine.arguments.dropFirst()))
    switch command {
    case let .validate(manifestPath, identity):
        let manifest = try readManifest(at: manifestPath)
        let validated = try validatedIdentity(identity, manifest: manifest)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let output = try encoder.encode(validated)
        FileHandle.standardOutput.write(output)
        FileHandle.standardOutput.write(Data("\n".utf8))
    case let .apply(rootPath, manifestPath, identity):
        let result = try apply(rootPath: rootPath, manifestPath: manifestPath, identity: identity)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let output = try encoder.encode(result)
        FileHandle.standardOutput.write(output)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

do {
    try main()
} catch let error as BootstrapError {
    FileHandle.standardError.write(Data("bootstrap validation failed: \(error.message)\n".utf8))
    exit(1)
} catch {
    FileHandle.standardError.write(Data("bootstrap validation failed\n".utf8))
    exit(1)
}
