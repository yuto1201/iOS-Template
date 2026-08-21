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
}

enum BootstrapError: Error {
    case usage
    case unreadableManifest
    case unsupportedManifest
    case invalidIdentity

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
    guard arguments.first == "validate" else {
        throw BootstrapError.usage
    }

    let values = Array(arguments.dropFirst())
    guard values.count == 10 else {
        throw BootstrapError.usage
    }

    var options: [String: String] = [:]
    var index = 0
    while index < values.count {
        let flag = values[index]
        let value = values[index + 1]
        guard ["--manifest", "--display-name", "--module-name", "--app-slug", "--bundle-id"].contains(flag),
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

    return .validate(
        manifestPath: manifestPath,
        identity: AppIdentity(
            displayName: displayName,
            moduleName: moduleName,
            appSlug: appSlug,
            bundleId: bundleId
        )
    )
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

    guard matches(normalized.displayName, pattern: "^[^/\\\\\\p{Cc}]{1,30}$"),
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
