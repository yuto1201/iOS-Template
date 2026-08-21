#!/usr/bin/env swift

import CoreFoundation
import CryptoKit
import Darwin
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
let batchPattern = try! NSRegularExpression(pattern: "^[A-Za-z0-9][A-Za-z0-9-]{0,63}$")
let udidPattern = try! NSRegularExpression(pattern: "^[0-9A-Fa-f-]+$")
let bundleIdentifierPattern = try! NSRegularExpression(
    pattern: "^[A-Za-z0-9][A-Za-z0-9-]*(\\.[A-Za-z0-9][A-Za-z0-9-]*)+$"
)
let testIdentifierPattern = try! NSRegularExpression(
    pattern: "^[A-Za-z_][A-Za-z0-9_.-]*/[A-Za-z_][A-Za-z0-9_.-]*/[A-Za-z_][A-Za-z0-9_.-]*$"
)
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

func requireISO8601Date(_ value: Any, at path: String) throws -> Date {
    let string = try requireString(value, at: path)
    guard matches(string, regex: iso8601Pattern) else {
        throw ValidationFailure("\(path) must be a complete ISO 8601 timestamp")
    }
    let dateParts = string.prefix(10).split(separator: "-").compactMap { Int($0) }
    guard dateParts.count == 3, (1...9999).contains(dateParts[0]) else {
        throw ValidationFailure("\(path) must be a valid ISO 8601 timestamp")
    }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let requestedDay = DateComponents(year: dateParts[0], month: dateParts[1], day: dateParts[2])
    guard let calendarDate = calendar.date(from: requestedDay) else {
        throw ValidationFailure("\(path) must be a valid ISO 8601 timestamp")
    }
    let actualDay = calendar.dateComponents([.year, .month, .day], from: calendarDate)
    guard actualDay.year == requestedDay.year,
          actualDay.month == requestedDay.month,
          actualDay.day == requestedDay.day else {
        throw ValidationFailure("\(path) must be a valid ISO 8601 timestamp")
    }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    if let date = formatter.date(from: string) { return date }
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard let date = formatter.date(from: string) else {
        throw ValidationFailure("\(path) must be a valid ISO 8601 timestamp")
    }
    return date
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

func readAll(_ fileDescriptor: Int32, at path: String) throws -> Data {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 16_384)
    while true {
        let count = read(fileDescriptor, &buffer, buffer.count)
        if count == 0 { return data }
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else {
            throw ValidationFailure("\(path) could not be read")
        }
        data.append(buffer, count: Int(count))
    }
}

func openRepositoryRoot(_ path: String) throws -> Int32 {
    let fileDescriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard fileDescriptor >= 0 else {
        throw ValidationFailure("Git top-level is unavailable or a symbolic link")
    }
    var information = stat()
    guard fstat(fileDescriptor, &information) == 0, (information.st_mode & S_IFMT) == S_IFDIR else {
        close(fileDescriptor)
        throw ValidationFailure("Git top-level is not a directory")
    }
    return fileDescriptor
}

func readBoundRegularFile(
    rootFileDescriptor: Int32,
    components: [String],
    at path: String
) throws -> Data {
    guard !components.isEmpty,
          components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") }) else {
        throw ValidationFailure("\(path) must be lexically contained")
    }

    var directory = dup(rootFileDescriptor)
    guard directory >= 0 else {
        throw ValidationFailure("unable to bind repository directory")
    }
    defer { close(directory) }

    for component in components.dropLast() {
        let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard next >= 0 else {
            throw ValidationFailure("\(path) is unavailable or contains a symbolic link")
        }
        var information = stat()
        guard fstat(next, &information) == 0, (information.st_mode & S_IFMT) == S_IFDIR else {
            close(next)
            throw ValidationFailure("\(path) contains a non-directory component")
        }
        close(directory)
        directory = next
    }

    let fileDescriptor = openat(directory, components.last!, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fileDescriptor >= 0 else {
        throw ValidationFailure("\(path) is unavailable or contains a symbolic link")
    }
    defer { close(fileDescriptor) }
    var information = stat()
    guard fstat(fileDescriptor, &information) == 0, (information.st_mode & S_IFMT) == S_IFREG else {
        throw ValidationFailure("\(path) must be a regular non-symbolic-link file")
    }
    guard information.st_nlink == 1 else {
        throw ValidationFailure("\(path) must have exactly one hard link")
    }
    return try readAll(fileDescriptor, at: path)
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

func sha256(data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func validateDigest(_ value: Any, data: Data, at path: String) throws {
    let recorded = try requireString(value, at: path)
    guard matches(recorded, regex: digestPattern) else {
        throw ValidationFailure("\(path) must use sha256:<64 lowercase hex>")
    }
    guard recorded == "sha256:\(sha256(data: data))" else {
        throw ValidationFailure("\(path) does not match exact file bytes")
    }
}

struct ProcessResult {
    let status: Int32
    let stdout: Data
}

func runGitProcess(_ arguments: [String]) throws -> ProcessResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = URL(
        fileURLWithPath: FileManager.default.currentDirectoryPath,
        isDirectory: true
    )
    var environment = ProcessInfo.processInfo.environment
    for key in [
        "GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE",
        "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES"
    ] {
        environment.removeValue(forKey: key)
    }
    for key in Array(environment.keys) where key == "GIT_CONFIG_COUNT" || key.hasPrefix("GIT_CONFIG_KEY_") || key.hasPrefix("GIT_CONFIG_VALUE_") {
        environment.removeValue(forKey: key)
    }
    environment["GIT_NO_REPLACE_OBJECTS"] = "1"
    process.environment = environment
    let stdout = Pipe()
    process.standardOutput = stdout
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
    } catch {
        throw ValidationFailure("unable to execute trusted Git inspection")
    }
    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return ProcessResult(status: process.terminationStatus, stdout: data)
}

func runGitString(_ arguments: [String], failure: String) throws -> String {
    let result = try runGitProcess(arguments)
    guard result.status == 0 else { throw ValidationFailure(failure) }
    guard let output = String(data: result.stdout, encoding: .utf8), !output.contains("\0") else {
        throw ValidationFailure("Git returned unsafe text output")
    }
    return output.trimmingCharacters(in: .whitespacesAndNewlines)
}

struct TrustedRepository {
    let rootPath: String
    let rootFileDescriptor: Int32
}

func validateTrustedRepository(expectedBase: String, expectedHead: String) throws -> TrustedRepository {
    let topLevel = try runGitString(
        ["rev-parse", "--show-toplevel"],
        failure: "current directory is not a Git worktree"
    )
    let gitRoot = URL(fileURLWithPath: topLevel, isDirectory: true)
        .resolvingSymlinksInPath().standardizedFileURL.path
    let currentDirectory = URL(
        fileURLWithPath: FileManager.default.currentDirectoryPath,
        isDirectory: true
    ).resolvingSymlinksInPath().standardizedFileURL.path
    guard currentDirectory == gitRoot else {
        throw ValidationFailure("validator must run from the Git top-level")
    }

    let currentHead = try runGitString(["rev-parse", "HEAD"], failure: "unable to resolve current Git HEAD")
    guard expectedHead == currentHead else {
        throw ValidationFailure("--expected-head must equal current Git HEAD")
    }
    for (sha, label) in [(expectedBase, "expected Base"), (expectedHead, "expected Head")] {
        let resolved = try runGitString(
            ["rev-parse", "--verify", "\(sha)^{commit}"],
            failure: "\(label) is not a resolvable commit"
        )
        guard resolved == sha else {
            throw ValidationFailure("\(label) must resolve to its exact 40-character commit")
        }
    }
    guard expectedBase != expectedHead else {
        throw ValidationFailure("expected Base and Head must differ")
    }
    let ancestor = try runGitProcess(["merge-base", "--is-ancestor", expectedBase, expectedHead])
    guard ancestor.status == 0 else {
        throw ValidationFailure("expected Base is not an ancestor of expected Head")
    }
    return TrustedRepository(rootPath: gitRoot, rootFileDescriptor: try openRepositoryRoot(gitRoot))
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
    guard developerPath.hasPrefix("/"),
          (developerPath as NSString).standardizingPath == developerPath else {
        throw ValidationFailure("\(path).path must be an absolute normalized path")
    }
    return XcodeIdentity(
        path: developerPath,
        version: try requireString(xcode["version"]!, at: "\(path).version"),
        build: try requireString(xcode["build"]!, at: "\(path).build")
    )
}

struct IssueContract {
    let acceptanceIDs: [String]
    let fetchedAt: Date
}

func validateOptionalVerification(_ value: Any) throws {
    let verification = try requireObject(value, at: "issueContract.verification")
    try requireExactKeys(
        verification, ["bundleIdentifier", "cases"], at: "issueContract.verification"
    )
    let bundleIdentifier = try requireString(
        verification["bundleIdentifier"]!, at: "issueContract.verification.bundleIdentifier"
    )
    guard matches(bundleIdentifier, regex: bundleIdentifierPattern) else {
        throw ValidationFailure("issueContract.verification.bundleIdentifier is invalid")
    }
    let expectedIDs = ["iphone-en", "iphone-ja", "ipad-en", "ipad-ja"]
    let cases = try requireArray(verification["cases"]!, at: "issueContract.verification.cases")
    guard cases.count == expectedIDs.count else {
        throw ValidationFailure("issueContract.verification.cases must contain the exact four ordered case IDs")
    }
    for (index, rawCase) in cases.enumerated() {
        let path = "issueContract.verification.cases[\(index)]"
        let entry = try requireObject(rawCase, at: path)
        let keys = Set(entry.keys)
        let testKeys: Set<String> = ["id", "testIdentifier"]
        let assertionKeys: Set<String> = ["id", "assertion"]
        guard keys == testKeys || keys == assertionKeys else {
            throw ValidationFailure("\(path) must contain exactly one of testIdentifier or assertion")
        }
        guard try requireString(entry["id"]!, at: "\(path).id") == expectedIDs[index] else {
            throw ValidationFailure("issueContract.verification.cases must contain the exact four ordered case IDs")
        }
        if keys == testKeys {
            let identifier = try requireString(entry["testIdentifier"]!, at: "\(path).testIdentifier")
            guard matches(identifier, regex: testIdentifierPattern) else {
                throw ValidationFailure("\(path).testIdentifier must be Target/Class/testMethod")
            }
        } else {
            let assertion = try requireObject(entry["assertion"]!, at: "\(path).assertion")
            try requireExactKeys(assertion, ["kind"], at: "\(path).assertion")
            guard try requireString(assertion["kind"]!, at: "\(path).assertion.kind") == "launch-succeeded" else {
                throw ValidationFailure("\(path).assertion.kind is not supported")
            }
        }
    }
}

func validateIssueContract(
    reference: JSONObject,
    issue: Int,
    repository: TrustedRepository
) throws -> IssueContract {
    try requireExactKeys(reference, ["path", "digest"], at: "issueContract")
    let recordedPath = try requireString(reference["path"]!, at: "issueContract.path")
    let canonicalPath = ".artifacts/issues/\(issue)/issue-contract.json"
    guard recordedPath == canonicalPath else {
        throw ValidationFailure("issueContract.path must be \(canonicalPath)")
    }
    let data = try readBoundRegularFile(
        rootFileDescriptor: repository.rootFileDescriptor,
        components: [".artifacts", "issues", String(issue), "issue-contract.json"],
        at: "issueContract.path"
    )
    try validateDigest(reference["digest"]!, data: data, at: "issueContract.digest")
    let contract = try readJSONObject(data: data, at: "issueContract file")
    let requiredContractKeys: Set<String> = [
        "schemaVersion", "issue", "repository", "goal", "specAnchors", "acceptanceCriteria",
        "dependencies", "externalOperations", "fetchedAt"
    ]
    let allowedContractKeys = requiredContractKeys.union(["verification"])
    let actualContractKeys = Set(contract.keys)
    let missingContractKeys = requiredContractKeys.subtracting(actualContractKeys).sorted()
    let unknownContractKeys = actualContractKeys.subtracting(allowedContractKeys).sorted()
    guard missingContractKeys.isEmpty, unknownContractKeys.isEmpty else {
        var parts: [String] = []
        if !missingContractKeys.isEmpty {
            parts.append("missing keys \(missingContractKeys.joined(separator: ", "))")
        }
        if !unknownContractKeys.isEmpty {
            parts.append("unknown keys \(unknownContractKeys.joined(separator: ", "))")
        }
        throw ValidationFailure("issueContract file: \(parts.joined(separator: "; "))")
    }
    guard try requireInteger(contract["schemaVersion"]!, at: "issueContract.schemaVersion") == 1 else {
        throw ValidationFailure("issueContract.schemaVersion must be 1")
    }
    guard try requireInteger(contract["issue"]!, at: "issueContract.issue", minimum: 1) == issue else {
        throw ValidationFailure("issueContract.issue does not match requested Issue")
    }
    _ = try requireString(contract["repository"]!, at: "issueContract.repository")
    _ = try requireString(contract["goal"]!, at: "issueContract.goal")
    _ = try requireStringArray(
        contract["specAnchors"]!, at: "issueContract.specAnchors", nonempty: true, unique: true
    )
    let fetchedAt = try requireISO8601Date(contract["fetchedAt"]!, at: "issueContract.fetchedAt")
    guard fetchedAt <= Date().addingTimeInterval(300) else {
        throw ValidationFailure("issueContract.fetchedAt is implausibly in the future")
    }

    let dependencies = try requireArray(contract["dependencies"]!, at: "issueContract.dependencies")
    var seenDependencies = Set<Int>()
    for (index, dependency) in dependencies.enumerated() {
        let number = try requireInteger(dependency, at: "issueContract.dependencies[\(index)]", minimum: 1)
        guard seenDependencies.insert(number).inserted else {
            throw ValidationFailure("issueContract.dependencies must be unique")
        }
    }
    _ = try requireStringArray(
        contract["externalOperations"]!, at: "issueContract.externalOperations", unique: true
    )
    if let verification = contract["verification"] {
        try validateOptionalVerification(verification)
    }

    let rawCriteria = try requireArray(contract["acceptanceCriteria"]!, at: "issueContract.acceptanceCriteria")
    guard !rawCriteria.isEmpty else {
        throw ValidationFailure("issueContract.acceptanceCriteria must not be empty")
    }
    var ids: [String] = []
    for (index, rawCriterion) in rawCriteria.enumerated() {
        let path = "issueContract.acceptanceCriteria[\(index)]"
        let criterion = try requireObject(rawCriterion, at: path)
        try requireExactKeys(criterion, ["id", "text"], at: path)
        let id = try requireString(criterion["id"]!, at: "\(path).id")
        guard matches(id, regex: acceptancePattern) else {
            throw ValidationFailure("issueContract acceptance IDs must match AC-<positive integer>")
        }
        guard id == "AC-\(index + 1)" else {
            throw ValidationFailure("issueContract acceptance IDs must be stable, ordered, and start at AC-1")
        }
        _ = try requireString(criterion["text"]!, at: "\(path).text")
        ids.append(id)
    }
    guard Set(ids).count == ids.count else {
        throw ValidationFailure("issueContract acceptance IDs must be unique")
    }
    return IssueContract(acceptanceIDs: ids, fetchedAt: fetchedAt)
}

struct DeviceTypeIdentity: Equatable {
    let identifier: String
    let name: String
}

struct MatrixInfo {
    let xcode: XcodeIdentity
    let caseIDs: [String]
}

func validateMatrix(
    data: Data,
    recordedPath: String
) throws -> MatrixInfo {
    let pathComponents = try relativeComponents(recordedPath, at: "matrixFile")
    guard pathComponents.count == 4,
          pathComponents[0] == ".artifacts",
          pathComponents[1] == "batches",
          matches(pathComponents[2], regex: batchPattern),
          pathComponents[3] == "simulator-matrix.json" else {
        throw ValidationFailure("matrixFile must use the canonical safe batch path")
    }
    let batchID = pathComponents[2]
    let matrix = try readJSONObject(data: data, at: "matrixFile")
    try requireExactKeys(
        matrix,
        ["schemaVersion", "batchId", "resolvedAt", "xcode", "runtime", "cases"],
        at: "matrixFile"
    )
    guard try requireInteger(matrix["schemaVersion"]!, at: "matrixFile.schemaVersion") == 1 else {
        throw ValidationFailure("matrixFile.schemaVersion must be 1")
    }
    guard try requireString(matrix["batchId"]!, at: "matrixFile.batchId") == batchID else {
        throw ValidationFailure("matrixFile.batchId does not match its canonical path")
    }
    _ = try requireString(matrix["resolvedAt"]!, at: "matrixFile.resolvedAt")
    let xcode = try validateXcodeIdentity(matrix["xcode"]!, at: "matrixFile.xcode")
    let runtime = try requireObject(matrix["runtime"]!, at: "matrixFile.runtime")
    try requireExactKeys(runtime, ["identifier", "version"], at: "matrixFile.runtime")
    _ = try requireString(runtime["identifier"]!, at: "matrixFile.runtime.identifier")
    _ = try requireString(runtime["version"]!, at: "matrixFile.runtime.version")

    let expected: [(String, String, String, String)] = [
        ("iphone-en", "iPhone", "en_US", "en"),
        ("iphone-ja", "iPhone", "ja_JP", "ja"),
        ("ipad-en", "iPad", "en_US", "en"),
        ("ipad-ja", "iPad", "ja_JP", "ja")
    ]
    let cases = try requireArray(matrix["cases"]!, at: "matrixFile.cases")
    guard cases.count == expected.count else {
        throw ValidationFailure("matrixFile.cases must contain exactly four rows")
    }
    var familyTypes: [String: DeviceTypeIdentity] = [:]
    var udids = Set<String>()
    var caseIDs: [String] = []
    for (index, rawCase) in cases.enumerated() {
        let path = "matrixFile.cases[\(index)]"
        let entry = try requireObject(rawCase, at: path)
        try requireExactKeys(
            entry, ["id", "family", "deviceType", "locale", "language", "udid"], at: path
        )
        let id = try requireString(entry["id"]!, at: "\(path).id")
        let family = try requireString(entry["family"]!, at: "\(path).family")
        let locale = try requireString(entry["locale"]!, at: "\(path).locale")
        let language = try requireString(entry["language"]!, at: "\(path).language")
        let expectedRow = expected[index]
        guard id == expectedRow.0, family == expectedRow.1,
              locale == expectedRow.2, language == expectedRow.3 else {
            throw ValidationFailure("matrixFile.cases must use the exact standard order and locale rows")
        }
        let rawType = try requireObject(entry["deviceType"]!, at: "\(path).deviceType")
        try requireExactKeys(rawType, ["identifier", "name"], at: "\(path).deviceType")
        let deviceType = DeviceTypeIdentity(
            identifier: try requireString(rawType["identifier"]!, at: "\(path).deviceType.identifier"),
            name: try requireString(rawType["name"]!, at: "\(path).deviceType.name")
        )
        if let existing = familyTypes[family], existing != deviceType {
            throw ValidationFailure("matrixFile must use one Device Type per family")
        }
        familyTypes[family] = deviceType
        let udid = try requireString(entry["udid"]!, at: "\(path).udid")
        guard matches(udid, regex: udidPattern) else {
            throw ValidationFailure("\(path).udid is invalid")
        }
        guard udids.insert(udid).inserted else {
            throw ValidationFailure("matrixFile Simulator UDIDs must be unique")
        }
        caseIDs.append(id)
    }
    return MatrixInfo(xcode: xcode, caseIDs: caseIDs)
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

struct EvidenceCase {
    let id: String
    let screenshot: String
    let screenshotComponents: [String]
}

func validateApplicationCases(
    _ value: Any,
    matrixCaseIDs: [String],
    issue: Int,
    head: String,
    repository: TrustedRepository
) throws {
    let cases = try requireArray(value, at: "cases")
    guard cases.count == matrixCaseIDs.count else {
        throw ValidationFailure("cases must contain exactly the frozen matrix rows")
    }
    var seenIDs = Set<String>()
    var evidenceCases: [EvidenceCase] = []
    for (index, rawCase) in cases.enumerated() {
        let path = "cases[\(index)]"
        let entry = try requireObject(rawCase, at: path)
        try requireExactKeys(entry, ["id", "status", "screenshot"], at: path)
        let id = try requireString(entry["id"]!, at: "\(path).id")
        guard seenIDs.insert(id).inserted else {
            throw ValidationFailure("cases contain duplicate ID \(id)")
        }
        guard try requireString(entry["status"]!, at: "\(path).status") == "passed" else {
            throw ValidationFailure("\(path).status must be passed")
        }
        let screenshot = try requireString(entry["screenshot"]!, at: "\(path).screenshot")
        let screenshotComponents = try relativeComponents(screenshot, at: "\(path).screenshot")
        evidenceCases.append(EvidenceCase(id: id, screenshot: screenshot, screenshotComponents: screenshotComponents))
    }
    guard evidenceCases.map(\.id) == matrixCaseIDs else {
        throw ValidationFailure("cases must bind exactly to frozen matrix rows in order")
    }
    guard Set(evidenceCases.map(\.screenshot)).count == evidenceCases.count else {
        throw ValidationFailure("case screenshot paths must be unique")
    }
    for (index, evidenceCase) in evidenceCases.enumerated() {
        guard evidenceCase.screenshotComponents.first == evidenceCase.id else {
            throw ValidationFailure("cases[\(index)].screenshot must begin with its case ID")
        }
        _ = try readBoundRegularFile(
            rootFileDescriptor: repository.rootFileDescriptor,
            components: [".artifacts", "issues", String(issue), head] + evidenceCase.screenshotComponents,
            at: "cases[\(index)].screenshot"
        )
    }
}

func validateDocumentationPath(_ path: String) throws {
    guard let data = path.data(using: .utf8), String(data: data, encoding: .utf8) == path else {
        throw ValidationFailure("documentation-only diff contains a non-UTF-8 path")
    }
    guard !path.contains("\\"),
          !path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else {
        throw ValidationFailure("documentation-only diff contains an unsafe path")
    }
    let components = try relativeComponents(path, at: "documentation-only path")
    guard components.allSatisfy({ !$0.hasPrefix(".") }) else {
        throw ValidationFailure("documentation-only diff contains an unusual hidden path")
    }
    let allowed = path == "README.md" || path == "AGENTS.md" || (
        components.count >= 2 &&
        (components[0] == "docs" || components[0] == "specs") &&
        components.last!.hasSuffix(".md")
    )
    guard allowed else {
        throw ValidationFailure("documentation-only path is not allowlisted: \(path)")
    }
}

func validateDocumentationDiff(expectedBase: String, expectedHead: String) throws {
    let result = try runGitProcess(["diff", "--raw", "-z", "--no-renames", expectedBase, expectedHead, "--"])
    guard result.status == 0 else {
        throw ValidationFailure("unable to inspect trusted documentation-only range")
    }
    var fields = result.stdout.split(separator: 0, omittingEmptySubsequences: false)
    guard fields.last?.isEmpty == true else {
        throw ValidationFailure("Git raw diff was not NUL terminated")
    }
    fields.removeLast()
    guard !fields.isEmpty, fields.count.isMultiple(of: 2) else {
        throw ValidationFailure("trusted range contains no classifiable documentation changes")
    }

    var index = 0
    while index < fields.count {
        guard let header = String(data: Data(fields[index]), encoding: .utf8), header.hasPrefix(":") else {
            throw ValidationFailure("Git raw diff contains malformed metadata")
        }
        guard let path = String(data: Data(fields[index + 1]), encoding: .utf8) else {
            throw ValidationFailure("documentation-only diff contains a non-UTF-8 path")
        }
        let metadata = header.dropFirst().split(separator: " ").map(String.init)
        guard metadata.count == 5 else {
            throw ValidationFailure("Git raw diff contains malformed metadata")
        }
        let oldMode = metadata[0]
        let newMode = metadata[1]
        let status = metadata[4]
        if oldMode == "160000" || newMode == "160000" {
            throw ValidationFailure("documentation-only diff contains a gitlink or unsupported file type")
        }
        let modesAreAllowed: Bool
        switch status {
        case "A": modesAreAllowed = oldMode == "000000" && newMode == "100644"
        case "D": modesAreAllowed = oldMode == "100644" && newMode == "000000"
        case "M": modesAreAllowed = oldMode == "100644" && newMode == "100644"
        default: modesAreAllowed = false
        }
        guard modesAreAllowed else {
            throw ValidationFailure("documentation-only diff contains a type or mode change")
        }
        try validateDocumentationPath(path)
        index += 2
    }
}

struct Options {
    let file: String
    let expectedIssue: Int
    let expectedBase: String
    let expectedHead: String
}

func parseOptions(_ arguments: [String]) throws -> Options {
    var file: String?
    var expectedIssue: Int?
    var expectedBase: String?
    var expectedHead: String?
    var index = 0
    var seen = Set<String>()
    let allowed = ["--file", "--expected-issue", "--expected-base", "--expected-head"]
    while index < arguments.count {
        let option = arguments[index]
        guard allowed.contains(option) else { throw ValidationFailure("unknown argument: \(option)") }
        guard seen.insert(option).inserted else { throw ValidationFailure("duplicate argument: \(option)") }
        index += 1
        guard index < arguments.count else { throw ValidationFailure("missing value for \(option)") }
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
        case "--expected-base":
            guard matches(value, regex: shaPattern) else {
                throw ValidationFailure("--expected-base must be 40 lowercase hexadecimal characters")
            }
            expectedBase = value
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
    guard let file, let expectedIssue, let expectedBase, let expectedHead else {
        throw ValidationFailure(
            "usage: swift tools/validate-verify-json.swift --file verify.json --expected-issue 42 --expected-base <40hex> --expected-head <40hex>"
        )
    }
    return Options(file: file, expectedIssue: expectedIssue, expectedBase: expectedBase, expectedHead: expectedHead)
}

func absoluteStandardizedPath(_ path: String) -> String {
    if path.hasPrefix("/") { return (path as NSString).standardizingPath }
    return ((FileManager.default.currentDirectoryPath + "/" + path) as NSString).standardizingPath
}

func validate(options: Options) throws {
    let repository = try validateTrustedRepository(
        expectedBase: options.expectedBase,
        expectedHead: options.expectedHead
    )
    defer { close(repository.rootFileDescriptor) }

    let evidenceComponents = [
        ".artifacts", "issues", String(options.expectedIssue), options.expectedHead, "verify.json"
    ]
    let canonicalEvidencePath = repository.rootPath + "/" + evidenceComponents.joined(separator: "/")
    guard absoluteStandardizedPath(options.file) == canonicalEvidencePath else {
        throw ValidationFailure("--file must be the canonical evidence path: \(canonicalEvidencePath)")
    }
    let evidenceData = try readBoundRegularFile(
        rootFileDescriptor: repository.rootFileDescriptor,
        components: evidenceComponents,
        at: "verify.json"
    )
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
    guard issue == options.expectedIssue else { throw ValidationFailure("issue does not match --expected-issue") }
    let baseSha = try requireString(root["baseSha"]!, at: "baseSha")
    let headSha = try requireString(root["headSha"]!, at: "headSha")
    guard matches(baseSha, regex: shaPattern) else {
        throw ValidationFailure("baseSha must be 40 lowercase hexadecimal characters")
    }
    guard matches(headSha, regex: shaPattern) else {
        throw ValidationFailure("headSha must be 40 lowercase hexadecimal characters")
    }
    guard baseSha == options.expectedBase else {
        throw ValidationFailure("baseSha does not match --expected-base")
    }
    guard headSha == options.expectedHead else {
        throw ValidationFailure("headSha does not match --expected-head")
    }

    let contractReference = try requireObject(root["issueContract"]!, at: "issueContract")
    let contract = try validateIssueContract(
        reference: contractReference,
        issue: issue,
        repository: repository
    )
    let completedAt = try requireISO8601Date(root["completedAt"]!, at: "completedAt")
    guard completedAt >= contract.fetchedAt else {
        throw ValidationFailure("completedAt must not precede issueContract.fetchedAt")
    }
    guard completedAt <= Date().addingTimeInterval(300) else {
        throw ValidationFailure("completedAt is implausibly in the future")
    }

    let classification = try requireString(root["changeClassification"]!, at: "changeClassification")
    switch classification {
    case "application-code":
        guard try requireString(root["status"]!, at: "status") == "passed" else {
            throw ValidationFailure("application status must be passed")
        }
        try requireNull(root["reason"]!, at: "reason")

        let matrixPath = try requireString(root["matrixFile"]!, at: "matrixFile")
        let matrixComponents = try relativeComponents(matrixPath, at: "matrixFile")
        guard matrixComponents.count == 4,
              matrixComponents[0] == ".artifacts",
              matrixComponents[1] == "batches",
              matches(matrixComponents[2], regex: batchPattern),
              matrixComponents[3] == "simulator-matrix.json" else {
            throw ValidationFailure("matrixFile must use the canonical safe batch path")
        }
        let matrixData = try readBoundRegularFile(
            rootFileDescriptor: repository.rootFileDescriptor,
            components: matrixComponents,
            at: "matrixFile"
        )
        try validateDigest(root["matrixDigest"]!, data: matrixData, at: "matrixDigest")
        let matrix = try validateMatrix(data: matrixData, recordedPath: matrixPath)

        let route = try requireString(root["executionRoute"]!, at: "executionRoute")
        guard ["xcodebuild-simctl", "xcodebuild-mcp"].contains(route) else {
            throw ValidationFailure("executionRoute is not supported")
        }
        let xcode = try validateXcodeIdentity(root["xcode"]!, at: "xcode")
        guard xcode == matrix.xcode else {
            throw ValidationFailure("xcode identity must exactly match matrixFile.xcode")
        }
        try validateBuild(root["build"]!, documentationOnly: false)
        try validateTests(root["tests"]!, documentationOnly: false)
        try validateApplicationCases(
            root["cases"]!, matrixCaseIDs: matrix.caseIDs, issue: issue,
            head: headSha, repository: repository
        )
        try validateVisual(root["visualEvaluation"]!, documentationOnly: false)
        try validateAcceptanceEvidence(
            root["acceptanceEvidence"]!, contractIDs: contract.acceptanceIDs, documentationOnly: false
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
        guard try requireArray(root["cases"]!, at: "cases").isEmpty else {
            throw ValidationFailure("documentation-only cases must be empty")
        }
        try validateVisual(root["visualEvaluation"]!, documentationOnly: true)
        try validateAcceptanceEvidence(
            root["acceptanceEvidence"]!, contractIDs: contract.acceptanceIDs, documentationOnly: true
        )
        try validateDocumentationDiff(
            expectedBase: options.expectedBase,
            expectedHead: options.expectedHead
        )

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
