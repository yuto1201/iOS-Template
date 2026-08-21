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
    case audit(rootPath: String, manifestPath: String, moduleName: String)
    case changedPaths(rootPath: String, manifestPath: String)
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
          action == "validate" || action == "apply" || action == "audit" || action == "changed-paths" else {
        throw BootstrapError.usage
    }

    let values = Array(arguments.dropFirst())
    let expectedCount: Int
    switch action {
    case "apply":
        expectedCount = 12
    case "audit":
        expectedCount = 6
    case "changed-paths":
        expectedCount = 4
    default:
        expectedCount = 10
    }
    guard values.count == expectedCount else {
        throw BootstrapError.usage
    }

    var options: [String: String] = [:]
    let allowedFlags: [String]
    switch action {
    case "apply":
        allowedFlags = ["--root", "--manifest", "--display-name", "--module-name", "--app-slug", "--bundle-id"]
    case "audit":
        allowedFlags = ["--root", "--manifest", "--module-name"]
    case "changed-paths":
        allowedFlags = ["--root", "--manifest"]
    default:
        allowedFlags = ["--manifest", "--display-name", "--module-name", "--app-slug", "--bundle-id"]
    }
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

    guard let manifestPath = options["--manifest"] else {
        throw BootstrapError.usage
    }

    if action == "changed-paths" {
        guard let rootPath = options["--root"] else {
            throw BootstrapError.usage
        }
        return .changedPaths(rootPath: rootPath, manifestPath: manifestPath)
    }

    if action == "audit" {
        guard let rootPath = options["--root"],
              let moduleName = options["--module-name"] else {
            throw BootstrapError.usage
        }
        return .audit(rootPath: rootPath, manifestPath: manifestPath, moduleName: moduleName)
    }

    guard let displayName = options["--display-name"],
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

func identifierOccurrenceCount(of identifier: String, in text: String) -> Int {
    let escaped = NSRegularExpression.escapedPattern(for: identifier)
    guard let expression = try? NSRegularExpression(
        pattern: "(?<![A-Za-z0-9])\(escaped)(?![A-Za-z0-9])"
    ) else {
        return 0
    }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return expression.numberOfMatches(in: text, range: range)
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

func expectedLiveContentPaths(manifest: TemplateManifest) -> Set<String> {
    [
        "\(manifest.source.project).xcodeproj/project.pbxproj",
        "\(manifest.source.project).xcodeproj/xcshareddata/xcschemes/\(manifest.source.module).xcscheme",
        "\(manifest.source.module)/\(manifest.source.module)App.swift",
        "\(manifest.source.module)/ContentView.swift",
        "\(manifest.source.module)/Localizable.xcstrings",
        "\(manifest.source.module)Tests/\(manifest.source.module)Tests.swift",
        "\(manifest.source.module)UITests/\(manifest.source.module)UITests.swift",
        "AGENTS.md",
        "README.md",
        "Config/ownership.yml",
        "specs/architecture.md",
        "docs/verification.md",
        "docs/security.md",
        "docs/agent-contracts/review-packet.md",
    ]
}

func requireOccurrenceCount(_ needle: String, equals expected: Int, in path: URL) throws {
    guard let content = try? String(contentsOf: path, encoding: .utf8),
          countOccurrences(of: needle, in: content) == expected else {
        throw BootstrapError.missingAnchor
    }
}

func preflightSourceContract(root: URL, manifest: TemplateManifest) throws {
    let livePaths = Set(manifest.liveContentPaths)
    guard livePaths.count == manifest.liveContentPaths.count,
          livePaths == expectedLiveContentPaths(manifest: manifest) else {
        throw BootstrapError.unsupportedManifest
    }

    for livePath in manifest.liveContentPaths {
        try requireRegularItem(at: safePath(livePath, under: root), under: root)
    }

    let source = manifest.source.module
    let moduleAnchorCounts: [String: Int] = [
        "\(manifest.source.project).xcodeproj/project.pbxproj": 60,
        "\(manifest.source.project).xcodeproj/xcshareddata/xcschemes/\(source).xcscheme": 15,
        "\(source)/\(source)App.swift": 3,
        "\(source)/ContentView.swift": 1,
        "\(source)Tests/\(source)Tests.swift": 4,
        "\(source)UITests/\(source)UITests.swift": 3,
        "README.md": 19,
        "specs/architecture.md": 8,
        "docs/verification.md": 2,
        "docs/agent-contracts/review-packet.md": 1,
    ]
    for (relativePath, expectedCount) in moduleAnchorCounts {
        try requireOccurrenceCount(
            source,
            equals: expectedCount,
            in: safePath(relativePath, under: root)
        )
    }

    let pbxproj = try safePath("\(manifest.source.project).xcodeproj/project.pbxproj", under: root)
    try requireOccurrenceCount(
        "PRODUCT_BUNDLE_IDENTIFIER = \(manifest.source.bundleId);",
        equals: 2,
        in: pbxproj
    )
    try requireOccurrenceCount(
        "PRODUCT_BUNDLE_IDENTIFIER = \(manifest.source.bundleId)Tests;",
        equals: 2,
        in: pbxproj
    )
    try requireOccurrenceCount(
        "PRODUCT_BUNDLE_IDENTIFIER = \(manifest.source.bundleId)UITests;",
        equals: 2,
        in: pbxproj
    )

    try requireOccurrenceCount(
        "\"template.welcome\"",
        equals: 1,
        in: safePath("\(source)/ContentView.swift", under: root)
    )
    try requireOccurrenceCount(
        "\"template.welcome-title\"",
        equals: 1,
        in: safePath("\(source)/ContentView.swift", under: root)
    )
    try requireOccurrenceCount(
        "\"template.welcome\"",
        equals: 1,
        in: safePath("\(source)/Localizable.xcstrings", under: root)
    )
    try requireOccurrenceCount(
        "\"template.welcome\"",
        equals: 2,
        in: safePath("\(source)Tests/\(source)Tests.swift", under: root)
    )
    try requireOccurrenceCount(
        "\"template.welcome-title\"",
        equals: 1,
        in: safePath("\(source)UITests/\(source)UITests.swift", under: root)
    )
    try requireOccurrenceCount(
        "template-app",
        equals: 3,
        in: safePath("docs/security.md", under: root)
    )
    try requireOccurrenceCount(
        "# iOS-Template agent contract",
        equals: 1,
        in: safePath("AGENTS.md", under: root)
    )
    try requireOccurrenceCount(
        "  bundleId: null",
        equals: 1,
        in: safePath("Config/ownership.yml", under: root)
    )
}

func transformArchitecture(_ identity: AppIdentity, manifest: TemplateManifest, in path: URL) throws {
    guard let content = try? String(contentsOf: path, encoding: .utf8) else {
        throw BootstrapError.missingAnchor
    }
    let source = manifest.source.module
    let sourceRootBlock = """
├── \(source)/
├── \(source)Tests/
├── \(source)UITests/
├── \(source).xcodeproj/
"""
    let destinationRootBlock = """
├── \(identity.moduleName)/
├── \(identity.moduleName)Tests/
├── \(identity.moduleName)UITests/
├── \(identity.moduleName).xcodeproj/
"""
    let sourceAppBlock = """
\(source)/
├── \(source)App.swift
"""
    let destinationAppBlock = """
\(identity.moduleName)/
├── \(identity.moduleName)App.swift
"""
    guard countOccurrences(of: sourceRootBlock, in: content) == 1,
          countOccurrences(of: sourceAppBlock, in: content) == 1 else {
        throw BootstrapError.missingAnchor
    }
    let transformed = content
        .replacingOccurrences(of: sourceRootBlock, with: destinationRootBlock)
        .replacingOccurrences(of: sourceAppBlock, with: destinationAppBlock)
    do {
        try transformed.write(to: path, atomically: true, encoding: .utf8)
    } catch {
        throw BootstrapError.writeFailed
    }
}

func transformPBXProject(_ identity: AppIdentity, manifest: TemplateManifest, in path: URL) throws {
    guard let content = try? String(contentsOf: path, encoding: .utf8) else {
        throw BootstrapError.missingAnchor
    }
    let modulePlaceholder = "__IOS_TEMPLATE_BOOTSTRAP_MODULE__"
    let appBundlePlaceholder = "__IOS_TEMPLATE_BOOTSTRAP_APP_BUNDLE__"
    let unitBundlePlaceholder = "__IOS_TEMPLATE_BOOTSTRAP_UNIT_BUNDLE__"
    let uiBundlePlaceholder = "__IOS_TEMPLATE_BOOTSTRAP_UI_BUNDLE__"
    guard !content.contains(modulePlaceholder),
          !content.contains(appBundlePlaceholder),
          !content.contains(unitBundlePlaceholder),
          !content.contains(uiBundlePlaceholder) else {
        throw BootstrapError.malformedProject
    }

    let transformed = content
        .replacingOccurrences(
            of: "\(manifest.source.bundleId)UITests",
            with: uiBundlePlaceholder
        )
        .replacingOccurrences(
            of: "\(manifest.source.bundleId)Tests",
            with: unitBundlePlaceholder
        )
        .replacingOccurrences(
            of: "PRODUCT_BUNDLE_IDENTIFIER = \(manifest.source.bundleId);",
            with: "PRODUCT_BUNDLE_IDENTIFIER = \(appBundlePlaceholder);"
        )
        .replacingOccurrences(of: manifest.source.module, with: modulePlaceholder)
        .replacingOccurrences(of: modulePlaceholder, with: identity.moduleName)
        .replacingOccurrences(of: appBundlePlaceholder, with: identity.bundleId)
        .replacingOccurrences(of: unitBundlePlaceholder, with: "\(identity.bundleId)Tests")
        .replacingOccurrences(of: uiBundlePlaceholder, with: "\(identity.bundleId)UITests")
    do {
        try transformed.write(to: path, atomically: true, encoding: .utf8)
    } catch {
        throw BootstrapError.writeFailed
    }
}

func transformContent(root: URL, manifest: TemplateManifest, identity: AppIdentity) throws {
    try preflightSourceContract(root: root, manifest: manifest)
    let livePaths = Set(manifest.liveContentPaths)

    let pbxproj = try safePath("\(manifest.source.project).xcodeproj/project.pbxproj", under: root)
    try transformPBXProject(identity, manifest: manifest, in: pbxproj)

    let moduleContentPaths = [
        "\(manifest.source.project).xcodeproj/xcshareddata/xcschemes/\(manifest.source.module).xcscheme",
        "\(manifest.source.module)/\(manifest.source.module)App.swift",
        "\(manifest.source.module)/ContentView.swift",
        "\(manifest.source.module)Tests/\(manifest.source.module)Tests.swift",
        "\(manifest.source.module)UITests/\(manifest.source.module)UITests.swift",
        "README.md",
        "docs/verification.md",
        "docs/agent-contracts/review-packet.md",
    ]
    for livePath in moduleContentPaths {
        guard livePaths.contains(livePath) else {
            throw BootstrapError.unsupportedManifest
        }
        try replaceExactly(manifest.source.module, with: identity.moduleName, in: try safePath(livePath, under: root), minimumCount: 1)
    }
    try transformArchitecture(
        identity,
        manifest: manifest,
        in: safePath("specs/architecture.md", under: root)
    )

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
        let destinationParent = destination.deletingLastPathComponent()
        guard let siblingNames = try? FileManager.default.contentsOfDirectory(atPath: destinationParent.path) else {
            throw BootstrapError.invalidPath
        }
        let destinationName = destination.lastPathComponent.lowercased()
        let caseInsensitiveCollision = siblingNames.contains {
            $0.lowercased() == destinationName
        }
        guard destinations.insert(destination.path).inserted,
              !FileManager.default.fileExists(atPath: destination.path),
              !caseInsensitiveCollision else {
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
    let modulePlaceholder = "__IOS_TEMPLATE_BOOTSTRAP_MODULE__"
    let projectPlaceholder = "__IOS_TEMPLATE_BOOTSTRAP_PROJECT__"
    let unitPlaceholder = "__IOS_TEMPLATE_BOOTSTRAP_UNIT__"
    let uiPlaceholder = "__IOS_TEMPLATE_BOOTSTRAP_UI__"
    return path
        .replacingOccurrences(of: "\(manifest.source.module).xcodeproj", with: projectPlaceholder)
        .replacingOccurrences(of: "\(manifest.source.module)UITests", with: uiPlaceholder)
        .replacingOccurrences(of: "\(manifest.source.module)Tests", with: unitPlaceholder)
        .replacingOccurrences(of: manifest.source.module, with: modulePlaceholder)
        .replacingOccurrences(of: projectPlaceholder, with: "\(identity.moduleName).xcodeproj")
        .replacingOccurrences(of: uiPlaceholder, with: "\(identity.moduleName)UITests")
        .replacingOccurrences(of: unitPlaceholder, with: "\(identity.moduleName)Tests")
        .replacingOccurrences(of: modulePlaceholder, with: identity.moduleName)
}

func auditResiduals(root: URL, manifest: TemplateManifest, identity: AppIdentity) throws {
    let livePaths = Set(manifest.liveContentPaths)
    guard livePaths.count == manifest.liveContentPaths.count,
          livePaths == expectedLiveContentPaths(manifest: manifest) else {
        throw BootstrapError.unsupportedManifest
    }

    var contentBySourcePath: [String: String] = [:]
    for sourcePath in manifest.liveContentPaths {
        let transformedPath = transformedLivePath(sourcePath, manifest: manifest, identity: identity)
        let file = try safePath(transformedPath, under: root)
        try requireRegularItem(at: file, under: root)
        guard let content = try? String(contentsOf: file, encoding: .utf8) else {
            throw BootstrapError.missingAnchor
        }
        contentBySourcePath[sourcePath] = content
    }

    func content(_ sourcePath: String) throws -> String {
        guard let value = contentBySourcePath[sourcePath] else {
            throw BootstrapError.missingAnchor
        }
        return value
    }

    func require(_ needle: String, count expected: Int, in sourcePath: String) throws {
        guard countOccurrences(of: needle, in: try content(sourcePath)) == expected else {
            throw BootstrapError.missingAnchor
        }
    }

    let source = manifest.source.module
    let pbxPath = "\(manifest.source.project).xcodeproj/project.pbxproj"
    let schemePath = "\(manifest.source.project).xcodeproj/xcshareddata/xcschemes/\(source).xcscheme"
    let appPath = "\(source)/\(source)App.swift"
    let contentViewPath = "\(source)/ContentView.swift"
    let localizationPath = "\(source)/Localizable.xcstrings"
    let unitPath = "\(source)Tests/\(source)Tests.swift"
    let uiPath = "\(source)UITests/\(source)UITests.swift"

    let strictSourceResidualPaths = [
        pbxPath,
        schemePath,
        appPath,
        contentViewPath,
        localizationPath,
        unitPath,
        uiPath,
        "README.md",
        "docs/verification.md",
        "docs/agent-contracts/review-packet.md",
    ]
    let sourceIdentifiers = [
        "\(source)UITests",
        "\(source)Tests",
        "\(source)App",
        source,
    ]
    for sourcePath in strictSourceResidualPaths {
        let transformedContent = try content(sourcePath)
        guard !sourceIdentifiers.contains(where: {
            identifierOccurrenceCount(of: $0, in: transformedContent) > 0
        }) else {
            throw BootstrapError.missingAnchor
        }
    }

    try require("PRODUCT_BUNDLE_IDENTIFIER = \(identity.bundleId);", count: 2, in: pbxPath)
    try require("PRODUCT_BUNDLE_IDENTIFIER = \(identity.bundleId)Tests;", count: 2, in: pbxPath)
    try require("PRODUCT_BUNDLE_IDENTIFIER = \(identity.bundleId)UITests;", count: 2, in: pbxPath)
    try require("PRODUCT_BUNDLE_IDENTIFIER = \(manifest.source.bundleId);", count: 0, in: pbxPath)
    try require("PRODUCT_BUNDLE_IDENTIFIER = \(manifest.source.bundleId)Tests;", count: 0, in: pbxPath)
    try require("PRODUCT_BUNDLE_IDENTIFIER = \(manifest.source.bundleId)UITests;", count: 0, in: pbxPath)
    try require("BlueprintName = \"\(identity.moduleName)\"", count: 3, in: schemePath)
    try require("struct \(identity.moduleName)App: App", count: 1, in: appPath)
    try require("\"\(identity.appSlug).welcome\"", count: 1, in: contentViewPath)
    try require("\"\(identity.appSlug).welcome-title\"", count: 1, in: contentViewPath)
    try require("\"\(identity.appSlug).welcome\"", count: 1, in: localizationPath)
    try require("@testable import \(identity.moduleName)", count: 1, in: unitPath)
    try require("\"\(identity.appSlug).welcome\"", count: 2, in: unitPath)
    try require("final class \(identity.moduleName)UITests: XCTestCase", count: 1, in: uiPath)
    try require("\"\(identity.appSlug).welcome-title\"", count: 1, in: uiPath)

    try require("# \(identity.displayName) agent contract", count: 1, in: "AGENTS.md")
    try require("-project \(identity.moduleName).xcodeproj", count: 5, in: "README.md")
    try require("-scheme \(identity.moduleName)", count: 5, in: "README.md")
    try require("  bundleId: \(identity.bundleId)", count: 1, in: "Config/ownership.yml")
    try require("\"scheme\": \"\(identity.moduleName)\"", count: 1, in: "docs/verification.md")
    try require("tests:\(identity.moduleName)Tests/", count: 1, in: "docs/verification.md")
    try require("\"file\": \"\(identity.moduleName)/Settings/NotificationSettings.swift\"", count: 1, in: "docs/agent-contracts/review-packet.md")

    let architecture = try content("specs/architecture.md")
    guard identifierOccurrenceCount(of: source, in: architecture) == 2,
          architecture.contains("`\(source)` は最小の SwiftUI アプリ"),
          architecture.contains("`\(source)`をFeature実装のまま残しません"),
          architecture.contains("├── \(identity.moduleName)/"),
          architecture.contains("├── \(identity.moduleName)Tests/"),
          architecture.contains("├── \(identity.moduleName)UITests/"),
          architecture.contains("├── \(identity.moduleName).xcodeproj/"),
          architecture.contains("\(identity.moduleName)/\n├── \(identity.moduleName)App.swift") else {
        throw BootstrapError.missingAnchor
    }

    let security = try content("docs/security.md")
    guard countOccurrences(of: "ios-template/\(identity.appSlug)/", in: security) == 3,
          countOccurrences(of: "ios-template/template-app/", in: security) == 0,
          security.contains("~/Library/Application Support/iOS-Template/secrets/${appSlug}/") else {
        throw BootstrapError.missingAnchor
    }
}

func audit(rootPath: String, manifestPath: String, moduleName: String) throws {
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
    let identityURL = try safePath("Config/app-identity.json", under: root)
    guard !isSymbolicLink(identityURL),
          let data = FileManager.default.contents(atPath: identityURL.path),
          let record = try? JSONDecoder().decode(ResultIdentity.self, from: data),
          record.schemaVersion == 1,
          record.sourceIdentityVersion == manifest.schemaVersion,
          record.moduleName == moduleName else {
        throw BootstrapError.invalidIdentity
    }
    let identity = try validatedIdentity(
        AppIdentity(
            displayName: record.displayName,
            moduleName: record.moduleName,
            appSlug: record.appSlug,
            bundleId: record.bundleId
        ),
        manifest: manifest
    )
    try auditResiduals(root: root, manifest: manifest, identity: identity)
}

func changedPaths(rootPath: String, manifestPath: String) throws -> [String] {
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
    let identityURL = try safePath("Config/app-identity.json", under: root)
    guard !isSymbolicLink(identityURL),
          let data = FileManager.default.contents(atPath: identityURL.path),
          let record = try? JSONDecoder().decode(ResultIdentity.self, from: data),
          record.schemaVersion == 1,
          record.sourceIdentityVersion == 1 else {
        throw BootstrapError.invalidPath
    }
    let identity = try validatedIdentity(
        AppIdentity(
            displayName: record.displayName,
            moduleName: record.moduleName,
            appSlug: record.appSlug,
            bundleId: record.bundleId
        ),
        manifest: manifest
    )
    let renames = try resolvedPathRenames(manifest: manifest, identity: identity)
    let paths = Set(
        manifest.liveContentPaths
            + manifest.liveContentPaths.map { transformedLivePath($0, manifest: manifest, identity: identity) }
            + renames.flatMap { [$0.source, $0.destination] }
            + ["Config/app-identity.json"]
    )
    for path in paths {
        guard !path.contains("\n"),
              !path.contains("\r") else {
            throw BootstrapError.invalidPath
        }
        _ = try safePath(path, under: root)
    }
    return paths.sorted()
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
    case let .audit(rootPath, manifestPath, moduleName):
        try audit(rootPath: rootPath, manifestPath: manifestPath, moduleName: moduleName)
    case let .changedPaths(rootPath, manifestPath):
        for path in try changedPaths(rootPath: rootPath, manifestPath: manifestPath) {
            FileHandle.standardOutput.write(Data("\(path)\n".utf8))
        }
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
