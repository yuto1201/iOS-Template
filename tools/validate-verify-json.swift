#!/usr/bin/env swift

import CryptoKit
import CoreFoundation
import Foundation

struct ValidationFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

typealias JSONObject = [String: Any]

let shaPattern = try! NSRegularExpression(pattern: "^[0-9a-f]{40}$")
let digestPattern = try! NSRegularExpression(pattern: "^sha256:[0-9a-f]{64}$")
let acceptancePattern = try! NSRegularExpression(pattern: "^AC-[1-9][0-9]*$")
let iso8601Pattern = try! NSRegularExpression(
    pattern: "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$"
)

func matches(_ value: String, regex: NSRegularExpression) -> Bool {
    let range = NSRange(value.startIndex..<value.endIndex, in: value)
    return regex.firstMatch(in: value, range: range)?.range == range
}

func requireExactKeys(_ object: JSONObject, _ keys: Set<String>, at path: String) throws {
    let actual = Set(object.keys)
    let missing = keys.subtracting(actual).sorted()
    let unknown = actual.subtracting(keys).sorted()
    guard missing.isEmpty, unknown.isEmpty else {
        var parts: [String] = []
        if !missing.isEmpty { parts.append("missing keys \(missing.joined(separator: ", "))") }
        if !unknown.isEmpty { parts.append("unknown keys \(unknown.joined(separator: ", "))") }
        throw ValidationFailure("\(path): \(parts.joined(separator: "; "))")
    }
}

func requireObject(_ value: Any, at path: String) throws -> JSONObject {
    guard let object = value as? JSONObject else {
        throw ValidationFailure("\(path) must be an object")
    }
    return object
}

func requireArray(_ value: Any, at path: String) throws -> [Any] {
    guard let array = value as? [Any] else {
        throw ValidationFailure("\(path) must be an array")
    }
    return array
}

func requireString(_ value: Any, at path: String, nonempty: Bool = true) throws -> String {
    guard let string = value as? String else {
        throw ValidationFailure("\(path) must be a string")
    }
    if nonempty && string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        throw ValidationFailure("\(path) must not be empty")
    }
    return string
}

func requireInteger(_ value: Any, at path: String, minimum: Int? = nil) throws -> Int {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
        throw ValidationFailure("\(path) must be an integer")
    }
    let type = String(cString: number.objCType)
    guard !["f", "d"].contains(type) else {
        throw ValidationFailure("\(path) must be an integer")
    }
    let integer = number.intValue
    if let minimum, integer < minimum {
        throw ValidationFailure("\(path) must be at least \(minimum)")
    }
    return integer
}

func requireNull(_ value: Any, at path: String) throws {
    guard value is NSNull else {
        throw ValidationFailure("\(path) must be null")
    }
}

func requireStringArray(
    _ value: Any,
    at path: String,
    nonempty: Bool = false,
    unique: Bool = false
) throws -> [String] {
    let raw = try requireArray(value, at: path)
    if nonempty && raw.isEmpty {
        throw ValidationFailure("\(path) must not be empty")
    }
    let strings = try raw.enumerated().map { index, entry in
        try requireString(entry, at: "\(path)[\(index)]")
    }
    if unique && Set(strings).count != strings.count {
        throw ValidationFailure("\(path) must contain unique values")
    }
    return strings
}

func requireISO8601(_ value: Any, at path: String) throws -> String {
    let string = try requireString(value, at: path)
    guard matches(string, regex: iso8601Pattern) else {
        throw ValidationFailure("\(path) must be a complete ISO 8601 timestamp")
    }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    if formatter.date(from: string) == nil {
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard formatter.date(from: string) != nil else {
            throw ValidationFailure("\(path) must be a valid ISO 8601 timestamp")
        }
    }
    return string
}

func sha256(data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func validateDigest(_ value: Any, data: Data, at path: String) throws {
    let recorded = try requireString(value, at: path)
    guard matches(recorded, regex: digestPattern) else {
        throw ValidationFailure("\(path) must use sha256:<64 lowercase hex>")
    }
    let actual = "sha256:\(sha256(data: data))"
    guard recorded == actual else {
        throw ValidationFailure("\(path) does not match exact file bytes")
    }
}

func isContained(_ target: URL, in root: URL) -> Bool {
    let targetPath = target.standardizedFileURL.path
    let rootPath = root.standardizedFileURL.path
    return targetPath.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
}

func relativeComponents(_ path: String, at label: String) throws -> [String] {
    guard !path.isEmpty, !path.hasPrefix("/") else {
        throw ValidationFailure("\(label) must be a non-empty relative path")
    }
    let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
        throw ValidationFailure("\(label) must be lexically contained")
    }
    return components
}

func requireRegularFile(_ target: URL, relativeTo root: URL, at path: String) throws -> Data {
    let lexicalRoot = root.standardizedFileURL
    let lexicalTarget = target.standardizedFileURL
    guard isContained(lexicalTarget, in: lexicalRoot) else {
        throw ValidationFailure("\(path) escapes its allowed root")
    }

    let physicalRoot = lexicalRoot.resolvingSymlinksInPath()
    let physicalTarget = lexicalTarget.resolvingSymlinksInPath()
    guard isContained(physicalTarget, in: physicalRoot) else {
        throw ValidationFailure("\(path) physically escapes its allowed root")
    }

    let relative = String(lexicalTarget.path.dropFirst(lexicalRoot.path.count))
        .split(separator: "/").map(String.init)
    var cursor = lexicalRoot
    for component in relative {
        cursor.appendPathComponent(component)
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: cursor.path)
        } catch {
            throw ValidationFailure("\(path) does not exist")
        }
        if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
            throw ValidationFailure("\(path) must not contain symbolic links")
        }
    }

    let attributes = try FileManager.default.attributesOfItem(atPath: lexicalTarget.path)
    guard attributes[.type] as? FileAttributeType == .typeRegular else {
        throw ValidationFailure("\(path) must be a regular file")
    }
    do {
        return try Data(contentsOf: lexicalTarget, options: [.mappedIfSafe])
    } catch {
        throw ValidationFailure("\(path) could not be read")
    }
}

func inferredRepositoryRoot(evidence: URL, issue: Int, head: String) -> URL {
    let marker = "/.artifacts/issues/\(issue)/\(head)/"
    let path = evidence.standardizedFileURL.path
    if let range = path.range(of: marker, options: .backwards) {
        let prefix = String(path[..<range.lowerBound])
        return URL(fileURLWithPath: prefix.isEmpty ? "/" : prefix, isDirectory: true)
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
}

func readJSONObject(data: Data, at path: String) throws -> JSONObject {
    let value: Any
    do {
        value = try JSONSerialization.jsonObject(with: data, options: [])
    } catch {
        throw ValidationFailure("\(path) is not valid JSON")
    }
    return try requireObject(value, at: path)
}

struct IssueContract {
    let acceptanceIDs: [String]
}

struct XcodeIdentity: Equatable {
    let path: String
    let version: String
    let build: String
}

func validateXcodeIdentity(_ value: Any, at path: String) throws -> XcodeIdentity {
    let xcode = try requireObject(value, at: path)
    try requireExactKeys(xcode, ["path", "version", "build"], at: path)
    let developerPath = try requireString(xcode["path"]!, at: "\(path).path")
    guard developerPath.hasPrefix("/"), URL(fileURLWithPath: developerPath).standardizedFileURL.path == developerPath else {
        throw ValidationFailure("\(path).path must be an absolute normalized path")
    }
    return XcodeIdentity(
        path: developerPath,
        version: try requireString(xcode["version"]!, at: "\(path).version"),
        build: try requireString(xcode["build"]!, at: "\(path).build")
    )
}

func validateIssueContract(
    reference: JSONObject,
    issue: Int,
    evidenceURL: URL,
    repositoryRoot: URL
) throws -> IssueContract {
    try requireExactKeys(reference, ["path", "digest"], at: "issueContract")
    let recordedPath = try requireString(reference["path"]!, at: "issueContract.path")
    let components = try relativeComponents(recordedPath, at: "issueContract.path")
    let canonicalPath = ".artifacts/issues/\(issue)/issue-contract.json"

    let allowedRoot: URL
    let contractURL: URL
    if recordedPath == canonicalPath {
        allowedRoot = repositoryRoot.appendingPathComponent(".artifacts/issues/\(issue)", isDirectory: true)
        contractURL = repositoryRoot.appendingPathComponent(components.joined(separator: "/"))
    } else {
        let fixtureRoot = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).appendingPathComponent("tools/tests/fixtures/verify", isDirectory: true)
        guard isContained(evidenceURL, in: fixtureRoot), recordedPath == "issue-contract.json" else {
            throw ValidationFailure("issueContract.path is not the canonical Issue contract path")
        }
        allowedRoot = evidenceURL.deletingLastPathComponent()
        contractURL = allowedRoot.appendingPathComponent(recordedPath)
    }

    let data = try requireRegularFile(contractURL, relativeTo: allowedRoot, at: "issueContract.path")
    try validateDigest(reference["digest"]!, data: data, at: "issueContract.digest")
    let contract = try readJSONObject(data: data, at: "issueContract file")
    try requireExactKeys(
        contract,
        ["schemaVersion", "issue", "repository", "goal", "specAnchors", "acceptanceCriteria", "dependencies", "externalOperations", "fetchedAt"],
        at: "issueContract file"
    )
    guard try requireInteger(contract["schemaVersion"]!, at: "issueContract.schemaVersion") == 1 else {
        throw ValidationFailure("issueContract.schemaVersion must be 1")
    }
    guard try requireInteger(contract["issue"]!, at: "issueContract.issue", minimum: 1) == issue else {
        throw ValidationFailure("issueContract.issue does not match requested Issue")
    }
    _ = try requireString(contract["repository"]!, at: "issueContract.repository")
    _ = try requireString(contract["goal"]!, at: "issueContract.goal")
    _ = try requireStringArray(contract["specAnchors"]!, at: "issueContract.specAnchors", nonempty: true, unique: true)
    _ = try requireISO8601(contract["fetchedAt"]!, at: "issueContract.fetchedAt")

    let dependencies = try requireArray(contract["dependencies"]!, at: "issueContract.dependencies")
    var seenDependencies = Set<Int>()
    for (index, dependency) in dependencies.enumerated() {
        let number = try requireInteger(dependency, at: "issueContract.dependencies[\(index)]", minimum: 1)
        guard seenDependencies.insert(number).inserted else {
            throw ValidationFailure("issueContract.dependencies must be unique")
        }
    }
    _ = try requireStringArray(
        contract["externalOperations"]!,
        at: "issueContract.externalOperations",
        unique: true
    )

    let rawCriteria = try requireArray(contract["acceptanceCriteria"]!, at: "issueContract.acceptanceCriteria")
    guard !rawCriteria.isEmpty else {
        throw ValidationFailure("issueContract.acceptanceCriteria must not be empty")
    }
    var ids: [String] = []
    for (index, rawCriterion) in rawCriteria.enumerated() {
        let criterion = try requireObject(rawCriterion, at: "issueContract.acceptanceCriteria[\(index)]")
        try requireExactKeys(criterion, ["id", "text"], at: "issueContract.acceptanceCriteria[\(index)]")
        let id = try requireString(criterion["id"]!, at: "issueContract.acceptanceCriteria[\(index)].id")
        guard matches(id, regex: acceptancePattern) else {
            throw ValidationFailure("issueContract acceptance IDs must match AC-<positive integer>")
        }
        guard id == "AC-\(index + 1)" else {
            throw ValidationFailure("issueContract acceptance IDs must be stable, ordered, and start at AC-1")
        }
        _ = try requireString(criterion["text"]!, at: "issueContract.acceptanceCriteria[\(index)].text")
        ids.append(id)
    }
    guard Set(ids).count == ids.count else {
        throw ValidationFailure("issueContract acceptance IDs must be unique")
    }
    return IssueContract(acceptanceIDs: ids)
}

func validateAcceptanceEvidence(
    _ value: Any,
    contractIDs: [String],
    documentationOnly: Bool
) throws {
    let entries = try requireArray(value, at: "acceptanceEvidence")
    var seen = Set<String>()
    for (index, rawEntry) in entries.enumerated() {
        let path = "acceptanceEvidence[\(index)]"
        let entry = try requireObject(rawEntry, at: path)
        try requireExactKeys(entry, ["id", "status", "evidence"], at: path)
        let id = try requireString(entry["id"]!, at: "\(path).id")
        guard seen.insert(id).inserted else {
            throw ValidationFailure("acceptanceEvidence contains duplicate ID \(id)")
        }
        guard try requireString(entry["status"]!, at: "\(path).status") == "passed" else {
            throw ValidationFailure("\(path).status must be passed")
        }
        let evidence = try requireStringArray(entry["evidence"]!, at: "\(path).evidence", nonempty: true)
        if documentationOnly {
            guard evidence.allSatisfy({ item in
                (item.hasPrefix("documents:") && item.dropFirst("documents:".count).contains(where: { !$0.isWhitespace })) ||
                (item.hasPrefix("links:") && item.dropFirst("links:".count).contains(where: { !$0.isWhitespace }))
            }) else {
                throw ValidationFailure("documentation-only acceptance evidence must cite document or link checks")
            }
        }
    }
    guard entries.count == contractIDs.count, seen == Set(contractIDs) else {
        throw ValidationFailure("acceptanceEvidence must contain every Issue contract AC exactly once and no extras")
    }
}

func validateBuild(_ value: Any, documentationOnly: Bool) throws {
    let build = try requireObject(value, at: "build")
    try requireExactKeys(build, ["status", "scheme", "warningsAdded"], at: "build")
    if documentationOnly {
        guard try requireString(build["status"]!, at: "build.status") == "not-applicable" else {
            throw ValidationFailure("build.status must be not-applicable")
        }
        try requireNull(build["scheme"]!, at: "build.scheme")
        try requireNull(build["warningsAdded"]!, at: "build.warningsAdded")
    } else {
        guard try requireString(build["status"]!, at: "build.status") == "passed" else {
            throw ValidationFailure("build.status must be passed")
        }
        _ = try requireString(build["scheme"]!, at: "build.scheme")
        guard try requireInteger(build["warningsAdded"]!, at: "build.warningsAdded", minimum: 0) == 0 else {
            throw ValidationFailure("build.warningsAdded must be zero")
        }
    }
}

func validateTests(_ value: Any, documentationOnly: Bool) throws {
    let tests = try requireObject(value, at: "tests")
    try requireExactKeys(tests, ["status", "passed", "failed", "skipped"], at: "tests")
    if documentationOnly {
        guard try requireString(tests["status"]!, at: "tests.status") == "not-applicable" else {
            throw ValidationFailure("tests.status must be not-applicable")
        }
        try requireNull(tests["passed"]!, at: "tests.passed")
        try requireNull(tests["failed"]!, at: "tests.failed")
        try requireNull(tests["skipped"]!, at: "tests.skipped")
    } else {
        guard try requireString(tests["status"]!, at: "tests.status") == "passed" else {
            throw ValidationFailure("tests.status must be passed")
        }
        _ = try requireInteger(tests["passed"]!, at: "tests.passed", minimum: 1)
        guard try requireInteger(tests["failed"]!, at: "tests.failed", minimum: 0) == 0 else {
            throw ValidationFailure("tests.failed must be zero")
        }
        guard try requireInteger(tests["skipped"]!, at: "tests.skipped", minimum: 0) == 0 else {
            throw ValidationFailure("tests.skipped must be zero")
        }
    }
}

func validateVisual(_ value: Any, documentationOnly: Bool) throws {
    let visual = try requireObject(value, at: "visualEvaluation")
    try requireExactKeys(visual, ["status", "findings"], at: "visualEvaluation")
    let expectedStatus = documentationOnly ? "not-applicable" : "passed"
    guard try requireString(visual["status"]!, at: "visualEvaluation.status") == expectedStatus else {
        throw ValidationFailure("visualEvaluation.status must be \(expectedStatus)")
    }
    let findings = try requireArray(visual["findings"]!, at: "visualEvaluation.findings")
    guard findings.isEmpty else {
        throw ValidationFailure("visualEvaluation.findings must be empty for accepted evidence")
    }
}

func validateApplicationCases(_ value: Any, evidenceDirectory: URL) throws {
    let cases = try requireArray(value, at: "cases")
    let expectedIDs = ["iphone-en", "iphone-ja", "ipad-en", "ipad-ja"]
    guard cases.count == expectedIDs.count else {
        throw ValidationFailure("cases must contain exactly four entries")
    }
    var seen = Set<String>()
    for (index, rawCase) in cases.enumerated() {
        let path = "cases[\(index)]"
        let entry = try requireObject(rawCase, at: path)
        try requireExactKeys(entry, ["id", "status", "screenshot"], at: path)
        let id = try requireString(entry["id"]!, at: "\(path).id")
        guard seen.insert(id).inserted else {
            throw ValidationFailure("cases contain duplicate ID \(id)")
        }
        guard id == expectedIDs[index] else {
            throw ValidationFailure("cases must use exact stable order \(expectedIDs.joined(separator: ","))")
        }
        guard try requireString(entry["status"]!, at: "\(path).status") == "passed" else {
            throw ValidationFailure("\(path).status must be passed")
        }
        let screenshot = try requireString(entry["screenshot"]!, at: "\(path).screenshot")
        let components = try relativeComponents(screenshot, at: "\(path).screenshot")
        let screenshotURL = evidenceDirectory.appendingPathComponent(components.joined(separator: "/"))
        _ = try requireRegularFile(screenshotURL, relativeTo: evidenceDirectory, at: "\(path).screenshot")
    }
}

func runGit(_ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git"] + arguments
    process.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    let stdout = Pipe()
    process.standardOutput = stdout
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
    } catch {
        throw ValidationFailure("unable to execute git for documentation-only classification")
    }
    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw ValidationFailure("git rejected documentation-only classification input")
    }
    guard let output = String(data: data, encoding: .utf8) else {
        throw ValidationFailure("git returned non-UTF-8 output")
    }
    return output.trimmingCharacters(in: .whitespacesAndNewlines)
}

func validateResolvableCommit(_ sha: String, at path: String) throws {
    let resolved = try runGit(["rev-parse", "--verify", "\(sha)^{commit}"])
    guard resolved == sha else {
        throw ValidationFailure("\(path) is not an exact resolvable commit")
    }
}

func isForbiddenDocumentationChange(_ path: String) -> Bool {
    let lower = path.lowercased()
    let components = lower.split(separator: "/").map(String.init)
    let forbiddenExtensions: Set<String> = [
        "swift", "strings", "stringsdict", "xcstrings", "entitlements", "plist", "xcconfig",
        "png", "jpg", "jpeg", "gif", "heic", "svg", "pdf"
    ]
    let fileExtension = URL(fileURLWithPath: lower).pathExtension
    if forbiddenExtensions.contains(fileExtension) { return true }
    if components.contains(where: {
        $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") || $0.hasSuffix(".xcassets") ||
        $0.hasSuffix(".lproj") || $0 == "assets" || $0 == "config" || $0 == "configuration" ||
        $0 == "configurations"
    }) { return true }
    return lower.hasSuffix("project.pbxproj") || lower.hasSuffix(".config")
}

func validateDocumentationDiff(base: String, head: String) throws {
    try validateResolvableCommit(base, at: "baseSha")
    try validateResolvableCommit(head, at: "headSha")
    let output = try runGit(["diff", "--name-only", base, head, "--"])
    let changedPaths = output.split(separator: "\n").map(String.init)
    if let forbidden = changedPaths.first(where: isForbiddenDocumentationChange) {
        throw ValidationFailure("documentation-only classification includes forbidden change: \(forbidden)")
    }
}

struct Options {
    let file: String
    let expectedIssue: Int
    let expectedHead: String
}

func parseOptions(_ arguments: [String]) throws -> Options {
    var file: String?
    var expectedIssue: Int?
    var expectedHead: String?
    var index = 0
    var seen = Set<String>()
    while index < arguments.count {
        let option = arguments[index]
        guard ["--file", "--expected-issue", "--expected-head"].contains(option) else {
            throw ValidationFailure("unknown argument: \(option)")
        }
        guard seen.insert(option).inserted else {
            throw ValidationFailure("duplicate argument: \(option)")
        }
        index += 1
        guard index < arguments.count else {
            throw ValidationFailure("missing value for \(option)")
        }
        let value = arguments[index]
        switch option {
        case "--file":
            guard !value.isEmpty else { throw ValidationFailure("--file must not be empty") }
            file = value
        case "--expected-issue":
            guard let parsed = Int(value), parsed > 0 else {
                throw ValidationFailure("--expected-issue must be a positive integer")
            }
            expectedIssue = parsed
        case "--expected-head":
            guard matches(value, regex: shaPattern) else {
                throw ValidationFailure("--expected-head must be 40 lowercase hexadecimal characters")
            }
            expectedHead = value
        default:
            break
        }
        index += 1
    }
    guard let file, let expectedIssue, let expectedHead else {
        throw ValidationFailure("usage: swift tools/validate-verify-json.swift --file verify.json --expected-issue 42 --expected-head <40hex>")
    }
    return Options(file: file, expectedIssue: expectedIssue, expectedHead: expectedHead)
}

func validate(options: Options) throws {
    let evidenceURL = URL(fileURLWithPath: options.file).standardizedFileURL
    let evidenceDirectory = evidenceURL.deletingLastPathComponent()
    let evidenceData: Data
    do {
        evidenceData = try Data(contentsOf: evidenceURL, options: [.mappedIfSafe])
    } catch {
        throw ValidationFailure("verify file could not be read")
    }
    let root = try readJSONObject(data: evidenceData, at: "verify.json")
    try requireExactKeys(
        root,
        [
            "schemaVersion", "status", "changeClassification", "reason", "issue", "baseSha", "headSha",
            "issueContract", "matrixFile", "matrixDigest", "executionRoute", "xcode", "build", "tests", "cases",
            "visualEvaluation", "acceptanceEvidence", "completedAt"
        ],
        at: "verify.json"
    )

    guard try requireInteger(root["schemaVersion"]!, at: "schemaVersion") == 1 else {
        throw ValidationFailure("schemaVersion must be 1")
    }
    let issue = try requireInteger(root["issue"]!, at: "issue", minimum: 1)
    guard issue == options.expectedIssue else {
        throw ValidationFailure("issue does not match --expected-issue")
    }
    let baseSha = try requireString(root["baseSha"]!, at: "baseSha")
    let headSha = try requireString(root["headSha"]!, at: "headSha")
    guard matches(baseSha, regex: shaPattern) else {
        throw ValidationFailure("baseSha must be 40 lowercase hexadecimal characters")
    }
    guard matches(headSha, regex: shaPattern) else {
        throw ValidationFailure("headSha must be 40 lowercase hexadecimal characters")
    }
    guard headSha == options.expectedHead else {
        throw ValidationFailure("headSha does not match --expected-head")
    }

    let repositoryRoot = inferredRepositoryRoot(evidence: evidenceURL, issue: issue, head: headSha)
    let contractReference = try requireObject(root["issueContract"]!, at: "issueContract")
    let contract = try validateIssueContract(
        reference: contractReference,
        issue: issue,
        evidenceURL: evidenceURL,
        repositoryRoot: repositoryRoot
    )
    _ = try requireISO8601(root["completedAt"]!, at: "completedAt")

    let classification = try requireString(root["changeClassification"]!, at: "changeClassification")
    switch classification {
    case "application-code":
        guard try requireString(root["status"]!, at: "status") == "passed" else {
            throw ValidationFailure("application status must be passed")
        }
        try requireNull(root["reason"]!, at: "reason")

        let matrixPath = try requireString(root["matrixFile"]!, at: "matrixFile")
        let matrixComponents = try relativeComponents(matrixPath, at: "matrixFile")
        guard matrixPath.hasPrefix(".artifacts/batches/") else {
            throw ValidationFailure("matrixFile must be under .artifacts/batches")
        }
        let matrixURL = repositoryRoot.appendingPathComponent(matrixComponents.joined(separator: "/"))
        let matrixData = try requireRegularFile(matrixURL, relativeTo: repositoryRoot, at: "matrixFile")
        try validateDigest(root["matrixDigest"]!, data: matrixData, at: "matrixDigest")
        let matrix = try readJSONObject(data: matrixData, at: "matrixFile")
        guard let matrixXcodeValue = matrix["xcode"] else {
            throw ValidationFailure("matrixFile.xcode is missing")
        }
        let matrixXcode = try validateXcodeIdentity(matrixXcodeValue, at: "matrixFile.xcode")

        let route = try requireString(root["executionRoute"]!, at: "executionRoute")
        guard ["xcodebuild-simctl", "xcodebuild-mcp"].contains(route) else {
            throw ValidationFailure("executionRoute is not supported")
        }

        let xcode = try validateXcodeIdentity(root["xcode"]!, at: "xcode")
        guard xcode == matrixXcode else {
            throw ValidationFailure("xcode identity must exactly match matrixFile.xcode")
        }

        try validateBuild(root["build"]!, documentationOnly: false)
        try validateTests(root["tests"]!, documentationOnly: false)
        try validateApplicationCases(root["cases"]!, evidenceDirectory: evidenceDirectory)
        try validateVisual(root["visualEvaluation"]!, documentationOnly: false)
        try validateAcceptanceEvidence(
            root["acceptanceEvidence"]!,
            contractIDs: contract.acceptanceIDs,
            documentationOnly: false
        )

    case "documentation-only":
        guard try requireString(root["status"]!, at: "status") == "not-applicable" else {
            throw ValidationFailure("documentation-only status must be not-applicable")
        }
        _ = try requireString(root["reason"]!, at: "reason")
        try requireNull(root["matrixFile"]!, at: "matrixFile")
        try requireNull(root["matrixDigest"]!, at: "matrixDigest")
        try requireNull(root["xcode"]!, at: "xcode")
        guard try requireString(root["executionRoute"]!, at: "executionRoute") == "none" else {
            throw ValidationFailure("documentation-only executionRoute must be none")
        }
        try validateBuild(root["build"]!, documentationOnly: true)
        try validateTests(root["tests"]!, documentationOnly: true)
        let cases = try requireArray(root["cases"]!, at: "cases")
        guard cases.isEmpty else {
            throw ValidationFailure("documentation-only cases must be empty")
        }
        try validateVisual(root["visualEvaluation"]!, documentationOnly: true)
        try validateAcceptanceEvidence(
            root["acceptanceEvidence"]!,
            contractIDs: contract.acceptanceIDs,
            documentationOnly: true
        )
        try validateDocumentationDiff(base: baseSha, head: headSha)

    default:
        throw ValidationFailure("changeClassification is not supported")
    }
}

do {
    let options = try parseOptions(Array(CommandLine.arguments.dropFirst()))
    try validate(options: options)
    print("verification evidence is valid")
} catch let failure as ValidationFailure {
    FileHandle.standardError.write(Data("verify.json validation failed: \(failure.description)\n".utf8))
    exit(1)
} catch {
    FileHandle.standardError.write(Data("verify.json validation failed: unexpected error\n".utf8))
    exit(1)
}
