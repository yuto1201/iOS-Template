#!/usr/bin/env swift

import CoreFoundation
import CryptoKit
import Darwin
import Foundation
import ImageIO

struct ValidationFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

typealias JSONObject = [String: Any]
var heldValidatedCandidateFileDescriptor: Int32?

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

func openBoundDirectory(rootFileDescriptor: Int32, components: [String], at path: String) throws -> Int32 {
    var directory = dup(rootFileDescriptor)
    guard directory >= 0 else { throw ValidationFailure("unable to bind repository directory") }
    for component in components {
        let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        close(directory)
        guard next >= 0 else {
            throw ValidationFailure("\(path) is unavailable or contains a symbolic link")
        }
        directory = next
    }
    return directory
}

func publishValidatedCandidate(
    repository: TrustedRepository,
    evidenceDirectoryComponents: [String],
    candidateName: String
) throws {
    let directory = try openBoundDirectory(
        rootFileDescriptor: repository.rootFileDescriptor,
        components: evidenceDirectoryComponents,
        at: "evidence directory"
    )
    defer { close(directory) }
    let candidate = openat(directory, candidateName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard candidate >= 0 else { throw ValidationFailure("validated candidate changed before publication") }
    defer { close(candidate) }
    var information = stat()
    var pathInformation = stat()
    guard fstat(candidate, &information) == 0,
          fstatat(directory, candidateName, &pathInformation, AT_SYMLINK_NOFOLLOW) == 0,
          (information.st_mode & S_IFMT) == S_IFREG,
          information.st_nlink == 1,
          information.st_uid == getuid(),
          (information.st_mode & 0o777) == S_IRUSR,
          information.st_dev == pathInformation.st_dev,
          information.st_ino == pathInformation.st_ino else {
        throw ValidationFailure("validated candidate changed before publication")
    }
    if let held = heldValidatedCandidateFileDescriptor {
        var heldInformation = stat()
        guard fstat(held, &heldInformation) == 0,
              heldInformation.st_dev == information.st_dev,
              heldInformation.st_ino == information.st_ino,
              sha256(data: try readAll(held, at: "held verify.json candidate")) == sha256(data: try readAll(candidate, at: "verify.json candidate")) else {
            throw ValidationFailure("validated candidate changed before publication")
        }
    }
    guard linkat(directory, candidateName, directory, "verify.json", 0) == 0 else {
        if errno == EEXIST { throw ValidationFailure("canonical verify.json already exists") }
        throw ValidationFailure("validated candidate could not be published")
    }
    let published = openat(directory, "verify.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard published >= 0 else {
        _ = unlinkat(directory, "verify.json", 0)
        throw ValidationFailure("verify.json publication could not be verified")
    }
    defer { close(published) }
    var publishedInformation = stat()
    guard fstat(published, &publishedInformation) == 0,
          publishedInformation.st_dev == information.st_dev,
          publishedInformation.st_ino == information.st_ino,
          fsync(published) == 0,
          unlinkat(directory, candidateName, 0) == 0,
          fsync(directory) == 0 else {
        _ = unlinkat(directory, "verify.json", 0)
        throw ValidationFailure("verify.json publication could not be synchronized")
    }
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
    for key in Array(environment.keys) where key.hasPrefix("GIT_") {
        environment.removeValue(forKey: key)
    }
    environment["GIT_CONFIG_NOSYSTEM"] = "1"
    environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
    environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
    environment["GIT_CONFIG_COUNT"] = "0"
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
          URL(fileURLWithPath: developerPath).standardizedFileURL.path == developerPath else {
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
    let verification: VerificationInfo?
}

struct VerificationCaseInfo {
    let id: String
    let action: String
    let value: String
}

struct VerificationInfo {
    let bundleIdentifier: String
    let unitTestIdentifier: String
    let cases: [VerificationCaseInfo]
    let acceptanceMappings: [[String]]
}

func validateOptionalVerification(_ value: Any, acceptanceIDs: [String]) throws -> VerificationInfo {
    let verification = try requireObject(value, at: "issueContract.verification")
    try requireExactKeys(
        verification, ["bundleIdentifier", "unitTestIdentifier", "cases", "acceptanceMappings"], at: "issueContract.verification"
    )
    let bundleIdentifier = try requireString(
        verification["bundleIdentifier"]!, at: "issueContract.verification.bundleIdentifier"
    )
    guard matches(bundleIdentifier, regex: bundleIdentifierPattern) else {
        throw ValidationFailure("issueContract.verification.bundleIdentifier is invalid")
    }
    let unitTestIdentifier = try requireString(
        verification["unitTestIdentifier"]!, at: "issueContract.verification.unitTestIdentifier"
    )
    guard matches(unitTestIdentifier, regex: testIdentifierPattern) else {
        throw ValidationFailure("issueContract.verification.unitTestIdentifier must be Target/Class/testMethod")
    }
    let expectedIDs = ["iphone-en", "iphone-ja", "ipad-en", "ipad-ja"]
    let cases = try requireArray(verification["cases"]!, at: "issueContract.verification.cases")
    guard cases.count == expectedIDs.count else {
        throw ValidationFailure("issueContract.verification.cases must contain the exact four ordered case IDs")
    }
    let normalizedCases = try cases.enumerated().map { index, rawCase -> VerificationCaseInfo in
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
            return VerificationCaseInfo(id: expectedIDs[index], action: "testIdentifier", value: identifier)
        } else {
            let assertion = try requireObject(entry["assertion"]!, at: "\(path).assertion")
            try requireExactKeys(assertion, ["kind"], at: "\(path).assertion")
            guard try requireString(assertion["kind"]!, at: "\(path).assertion.kind") == "launch-succeeded" else {
                throw ValidationFailure("\(path).assertion.kind is not supported")
            }
            return VerificationCaseInfo(id: expectedIDs[index], action: "assertion", value: "launch-succeeded")
        }
    }
    let allowedChecks = [
        "stage:build", "stage:unit-tests",
        "case:iphone-en", "case:iphone-ja", "case:ipad-en", "case:ipad-ja",
        "visual:iphone-en", "visual:iphone-ja", "visual:ipad-en", "visual:ipad-ja"
    ]
    let allowedOrder = Dictionary(uniqueKeysWithValues: allowedChecks.enumerated().map { ($1, $0) })
    let mappings = try requireArray(
        verification["acceptanceMappings"]!, at: "issueContract.verification.acceptanceMappings"
    )
    guard mappings.count == acceptanceIDs.count else {
        throw ValidationFailure("issueContract.verification.acceptanceMappings must map every AC exactly once")
    }
    let normalizedMappings = try mappings.enumerated().map { index, rawMapping in
        let path = "issueContract.verification.acceptanceMappings[\(index)]"
        let mapping = try requireObject(rawMapping, at: path)
        try requireExactKeys(mapping, ["id", "checks"], at: path)
        guard try requireString(mapping["id"]!, at: "\(path).id") == acceptanceIDs[index] else {
            throw ValidationFailure("issueContract.verification.acceptanceMappings must follow the exact AC order")
        }
        let checks = try requireStringArray(mapping["checks"]!, at: "\(path).checks", nonempty: true, unique: true)
        guard checks.allSatisfy({ allowedOrder[$0] != nil }) else {
            throw ValidationFailure("\(path).checks contains an unknown verification check")
        }
        guard checks == checks.sorted(by: { allowedOrder[$0]! < allowedOrder[$1]! }) else {
            throw ValidationFailure("\(path).checks must use canonical verification-check order")
        }
        guard checks.contains(where: { $0.hasPrefix("stage:") || $0.hasPrefix("case:") }) else {
            throw ValidationFailure("\(path).checks must include an execution check")
        }
        return checks
    }
    return VerificationInfo(
        bundleIdentifier: bundleIdentifier,
        unitTestIdentifier: unitTestIdentifier,
        cases: normalizedCases,
        acceptanceMappings: normalizedMappings
    )
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
    let normalizedVerification: VerificationInfo?
    if let rawVerification = contract["verification"] {
        normalizedVerification = try validateOptionalVerification(rawVerification, acceptanceIDs: ids)
    } else {
        normalizedVerification = nil
    }
    return IssueContract(
        acceptanceIDs: ids,
        fetchedAt: fetchedAt,
        verification: normalizedVerification
    )
}

struct DeviceTypeIdentity: Equatable {
    let identifier: String
    let name: String
}

struct MatrixInfo {
    let xcode: XcodeIdentity
    let cases: [MatrixCaseInfo]

    var caseIDs: [String] { cases.map(\.id) }
}

struct MatrixCaseInfo {
    let id: String
    let locale: String
    let language: String
    let udid: String
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
    let resolvedAt = try requireISO8601Date(matrix["resolvedAt"]!, at: "matrixFile.resolvedAt")
    guard resolvedAt <= Date().addingTimeInterval(300) else {
        throw ValidationFailure("matrixFile.resolvedAt is implausibly in the future")
    }
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
    var normalizedCases: [MatrixCaseInfo] = []
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
        normalizedCases.append(MatrixCaseInfo(id: id, locale: locale, language: language, udid: udid))
    }
    return MatrixInfo(xcode: xcode, cases: normalizedCases)
}

func validateAcceptanceEvidence(
    _ value: Any,
    contractIDs: [String],
    documentationOnly: Bool,
    expectedMappings: [[String]]? = nil
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
        guard index < contractIDs.count else {
            throw ValidationFailure("acceptanceEvidence must contain every Issue contract AC exactly once and no extras")
        }
        guard id == contractIDs[index] else {
            throw ValidationFailure("acceptanceEvidence must follow the exact Issue contract AC order")
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
        } else if let expectedMappings {
            guard evidence == expectedMappings[index] else {
                throw ValidationFailure("\(path).evidence must exactly match the Issue contract acceptance mapping")
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
    let candidateFile: String?
    let expectedIssue: Int
    let expectedBase: String
    let expectedHead: String
}

struct RunnerSnapshotOptions {
    let issue: Int
    let expectedBase: String
    let expectedHead: String
    let issueContract: String
    let matrix: String
}

func parseRunnerSnapshotOptions(_ arguments: [String]) throws -> RunnerSnapshotOptions {
    var values: [String: String] = [:]
    var index = 0
    let allowed = Set(["--issue", "--expected-base", "--expected-head", "--issue-contract", "--matrix"])
    while index < arguments.count {
        let key = arguments[index]
        guard allowed.contains(key), values[key] == nil, index + 1 < arguments.count else {
            throw ValidationFailure("invalid runner snapshot arguments")
        }
        values[key] = arguments[index + 1]
        index += 2
    }
    guard let issueText = values["--issue"], let issue = Int(issueText), issue > 0,
          let expectedBase = values["--expected-base"], matches(expectedBase, regex: shaPattern),
          let expectedHead = values["--expected-head"], matches(expectedHead, regex: shaPattern),
          let issueContract = values["--issue-contract"],
          let matrix = values["--matrix"], values.count == allowed.count else {
        throw ValidationFailure("invalid runner snapshot arguments")
    }
    return RunnerSnapshotOptions(
        issue: issue,
        expectedBase: expectedBase,
        expectedHead: expectedHead,
        issueContract: issueContract,
        matrix: matrix
    )
}

func runnerSnapshot(options: RunnerSnapshotOptions) throws -> Data {
    let repository = try validateTrustedRepository(
        expectedBase: options.expectedBase,
        expectedHead: options.expectedHead
    )
    defer { close(repository.rootFileDescriptor) }
    let status = try runGitProcess(["status", "--porcelain", "--untracked-files=all"])
    guard status.status == 0, status.stdout.isEmpty else {
        throw ValidationFailure("working tree must be clean")
    }

    let expectedContract = ".artifacts/issues/\(options.issue)/issue-contract.json"
    guard options.issueContract == expectedContract else {
        throw ValidationFailure("issue contract must use the canonical path")
    }
    let contractComponents = try relativeComponents(options.issueContract, at: "issue contract")
    let contractData = try readBoundRegularFile(
        rootFileDescriptor: repository.rootFileDescriptor,
        components: contractComponents,
        at: "issue contract"
    )
    let contractDigest = "sha256:\(sha256(data: contractData))"
    let contract = try validateIssueContract(
        reference: ["path": options.issueContract, "digest": contractDigest],
        issue: options.issue,
        repository: repository
    )
    guard let verification = contract.verification else {
        throw ValidationFailure("application verification contract is absent")
    }

    let matrixComponents = try relativeComponents(options.matrix, at: "matrix")
    let matrixData = try readBoundRegularFile(
        rootFileDescriptor: repository.rootFileDescriptor,
        components: matrixComponents,
        at: "matrix"
    )
    let matrix = try validateMatrix(data: matrixData, recordedPath: options.matrix)
    guard verification.cases.map(\.id) == matrix.caseIDs else {
        throw ValidationFailure("verification cases do not match matrix cases")
    }

    let cases: [[String: Any]] = matrix.cases.enumerated().map { index, matrixCase in
        let action = verification.cases[index]
        return [
            "id": matrixCase.id,
            "locale": matrixCase.locale,
            "language": matrixCase.language,
            "udid": matrixCase.udid,
            "action": action.action,
            "value": action.value
        ]
    }
    let mappings: [[String: Any]] = contract.acceptanceIDs.enumerated().map { index, id in
        ["id": id, "checks": verification.acceptanceMappings[index]]
    }
    let rootDigest = sha256(data: Data(repository.rootPath.utf8))
    let worktreeName = URL(fileURLWithPath: repository.rootPath).lastPathComponent
        .replacingOccurrences(of: "[^A-Za-z0-9_.-]", with: "-", options: .regularExpression)
    let workspaceRoot = "/tmp/ios-template-verify/\(worktreeName)-\(rootDigest)/issue-\(options.issue)/\(options.expectedHead)"
    var document: [String: Any] = [
        "repositoryRoot": repository.rootPath,
        "workspaceRoot": workspaceRoot,
        "contractPath": options.issueContract,
        "contractDigest": contractDigest,
        "matrixPath": options.matrix,
        "matrixDigest": "sha256:\(sha256(data: matrixData))",
        "bundleIdentifier": verification.bundleIdentifier,
        "unitTestIdentifier": verification.unitTestIdentifier,
        "acceptanceIDs": contract.acceptanceIDs,
        "acceptanceMappings": mappings,
        "xcode": ["path": matrix.xcode.path, "version": matrix.xcode.version, "build": matrix.xcode.build],
        "cases": cases
    ]
    let prepared = try prepareRunnerWorkspace(
        worktreeID: "\(worktreeName)-\(rootDigest)",
        issue: options.issue,
        head: options.expectedHead
    )
    document["attemptRoot"] = prepared.attemptPath
    document["runState"] = prepared.attemptPath
    document["lockPath"] = prepared.lockPath
    document["lockReadyFIFO"] = prepared.readyFIFOPath
    document["lockControlFIFO"] = prepared.controlFIFOPath
    let configPath = prepared.attemptPath + "/config.json"
    let configData: Data
    do {
        configData = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]) + Data("\n".utf8)
        try writeExclusiveFile(
            directoryFileDescriptor: prepared.attemptFileDescriptor,
            name: "config.json",
            data: configData,
            permissions: S_IRUSR
        )
    } catch {
        close(prepared.attemptFileDescriptor)
        close(prepared.workspaceFileDescriptor)
        throw error
    }
    close(prepared.attemptFileDescriptor)
    close(prepared.workspaceFileDescriptor)
    let configDigest = "sha256:\(sha256(data: configData))"
    return Data([configPath, configDigest, workspaceRoot, prepared.attemptPath, prepared.lockPath,
                 prepared.readyFIFOPath, prepared.controlFIFOPath]
        .joined(separator: "\t").utf8)
}

func verifyRunnerInputs(
    options: RunnerSnapshotOptions,
    contractDigest: String,
    matrixDigest: String
) throws {
    guard matches(contractDigest, regex: digestPattern), matches(matrixDigest, regex: digestPattern) else {
        throw ValidationFailure("runner input digest is invalid")
    }
    let repository = try validateTrustedRepository(
        expectedBase: options.expectedBase,
        expectedHead: options.expectedHead
    )
    defer { close(repository.rootFileDescriptor) }
    let status = try runGitProcess(["status", "--porcelain", "--untracked-files=all"])
    guard status.status == 0, status.stdout.isEmpty else { throw ValidationFailure("working tree changed during verification") }
    let contractComponents = try relativeComponents(options.issueContract, at: "issue contract")
    let contractData = try readBoundRegularFile(
        rootFileDescriptor: repository.rootFileDescriptor,
        components: contractComponents,
        at: "issue contract"
    )
    guard "sha256:\(sha256(data: contractData))" == contractDigest else {
        throw ValidationFailure("contract changed during verification")
    }
    _ = try validateIssueContract(
        reference: ["path": options.issueContract, "digest": contractDigest],
        issue: options.issue,
        repository: repository
    )
    let matrixComponents = try relativeComponents(options.matrix, at: "matrix")
    let matrixData = try readBoundRegularFile(
        rootFileDescriptor: repository.rootFileDescriptor,
        components: matrixComponents,
        at: "matrix"
    )
    guard "sha256:\(sha256(data: matrixData))" == matrixDigest else {
        throw ValidationFailure("matrix changed during verification")
    }
    _ = try validateMatrix(data: matrixData, recordedPath: options.matrix)
}

struct PreparedRunnerWorkspace {
    let workspaceFileDescriptor: Int32
    let attemptFileDescriptor: Int32
    let attemptPath: String
    let lockPath: String
    let readyFIFOPath: String
    let controlFIFOPath: String
}

func securePrivateDirectory(parent: Int32, name: String, label: String) throws -> Int32 {
    guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
        throw ValidationFailure("\(label) has an unsafe component")
    }
    if mkdirat(parent, name, S_IRWXU) != 0, errno != EEXIST {
        throw ValidationFailure("\(label) could not be created")
    }
    let descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else {
        throw ValidationFailure("\(label) is unavailable or a symbolic link")
    }
    var information = stat()
    guard fstat(descriptor, &information) == 0,
          (information.st_mode & S_IFMT) == S_IFDIR,
          information.st_uid == getuid() else {
        close(descriptor)
        throw ValidationFailure("\(label) is not an owned directory")
    }
    if (information.st_mode & 0o777) != S_IRWXU {
        guard fchmod(descriptor, S_IRWXU) == 0 else {
            close(descriptor)
            throw ValidationFailure("\(label) permissions are not private")
        }
    }
    return descriptor
}

func writeExclusiveFile(
    directoryFileDescriptor: Int32,
    name: String,
    data: Data,
    permissions: mode_t = S_IRUSR | S_IWUSR
) throws {
    let descriptor = openat(
        directoryFileDescriptor, name,
        O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
        permissions
    )
    guard descriptor >= 0 else {
        throw ValidationFailure("exclusive file publication collided")
    }
    var succeeded = false
    defer {
        close(descriptor)
        if !succeeded { _ = unlinkat(directoryFileDescriptor, name, 0) }
    }
    try data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw ValidationFailure("exclusive file publication failed") }
            offset += count
        }
    }
    guard fchmod(descriptor, permissions) == 0 else {
        throw ValidationFailure("exclusive file permissions could not be sealed")
    }
    guard fsync(descriptor) == 0, fsync(directoryFileDescriptor) == 0 else {
        throw ValidationFailure("exclusive file publication could not be synchronized")
    }
    succeeded = true
}

func publishGeneratedData(
    directoryFileDescriptor: Int32,
    canonicalName: String,
    temporaryPrefix: String,
    data: Data
) throws {
    let temporaryName = "\(temporaryPrefix)-\(UUID().uuidString.lowercased())"
    try writeExclusiveFile(
        directoryFileDescriptor: directoryFileDescriptor,
        name: temporaryName,
        data: data,
        permissions: S_IRUSR
    )
    defer { _ = unlinkat(directoryFileDescriptor, temporaryName, 0) }
    let sealed = openat(directoryFileDescriptor, temporaryName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard sealed >= 0 else { throw ValidationFailure("sealed publication candidate is unavailable") }
    defer { close(sealed) }
    var sealedInformation = stat()
    guard fstat(sealed, &sealedInformation) == 0,
          sealedInformation.st_nlink == 1,
          sealedInformation.st_uid == getuid(),
          (sealedInformation.st_mode & 0o777) == S_IRUSR,
          sha256(data: try readAll(sealed, at: "sealed publication candidate")) == sha256(data: data) else {
        throw ValidationFailure("sealed publication candidate changed")
    }
    guard linkat(directoryFileDescriptor, temporaryName, directoryFileDescriptor, canonicalName, 0) == 0 else {
        if errno == EEXIST { throw ValidationFailure("canonical publication already exists") }
        throw ValidationFailure("canonical publication failed")
    }
    let published = openat(directoryFileDescriptor, canonicalName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard published >= 0 else {
        _ = unlinkat(directoryFileDescriptor, canonicalName, 0)
        throw ValidationFailure("canonical publication could not be verified")
    }
    defer { close(published) }
    var publishedInformation = stat()
    guard fstat(published, &publishedInformation) == 0,
          publishedInformation.st_dev == sealedInformation.st_dev,
          publishedInformation.st_ino == sealedInformation.st_ino,
          fsync(published) == 0,
          unlinkat(directoryFileDescriptor, temporaryName, 0) == 0,
          fsync(directoryFileDescriptor) == 0 else {
        _ = unlinkat(directoryFileDescriptor, canonicalName, 0)
        throw ValidationFailure("canonical publication could not be synchronized")
    }
}

func prepareRunnerWorkspace(worktreeID: String, issue: Int, head: String) throws -> PreparedRunnerWorkspace {
    let temporary = open("/tmp", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard temporary >= 0 else { throw ValidationFailure("trusted temporary root is unavailable") }
    defer { close(temporary) }
    var current = try securePrivateDirectory(parent: temporary, name: "ios-template-verify", label: "verification temporary root")
    for (name, label) in [
        (worktreeID, "worktree workspace"),
        ("issue-\(issue)", "Issue workspace"),
        (head, "Head workspace")
    ] {
        let next = try securePrivateDirectory(parent: current, name: name, label: label)
        close(current)
        current = next
    }
    let lockDescriptor = openat(
        current, ".verify.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
        S_IRUSR | S_IWUSR
    )
    guard lockDescriptor >= 0 else {
        close(current)
        throw ValidationFailure("verification advisory lock file is unavailable")
    }
    var lockInfo = stat()
    guard fstat(lockDescriptor, &lockInfo) == 0,
          (lockInfo.st_mode & S_IFMT) == S_IFREG,
          lockInfo.st_uid == getuid(),
          lockInfo.st_nlink == 1,
          fchmod(lockDescriptor, S_IRUSR | S_IWUSR) == 0 else {
        close(lockDescriptor)
        close(current)
        throw ValidationFailure("verification advisory lock file is unsafe")
    }
    close(lockDescriptor)
    let attempts = try securePrivateDirectory(parent: current, name: "Attempts", label: "attempts workspace")
    let attemptName = "attempt-\(UUID().uuidString.lowercased())"
    do {
        let attempt = try securePrivateDirectory(parent: attempts, name: attemptName, label: "runner attempt")
        close(attempts)
        for name in ["Cases", "Screenshots"] {
            let directory = try securePrivateDirectory(parent: attempt, name: name, label: "attempt \(name)")
            close(directory)
        }
        for name in ["lock-ready.fifo", "lock-control.fifo"] {
            guard mkfifoat(attempt, name, S_IRUSR | S_IWUSR) == 0 else {
                throw ValidationFailure("runner lock channel could not be created")
            }
        }
        let root = "/tmp/ios-template-verify/\(worktreeID)/issue-\(issue)/\(head)"
        close(attempts)
        return PreparedRunnerWorkspace(
            workspaceFileDescriptor: current,
            attemptFileDescriptor: attempt,
            attemptPath: root + "/Attempts/" + attemptName,
            lockPath: root + "/.verify.lock",
            readyFIFOPath: root + "/Attempts/" + attemptName + "/lock-ready.fifo",
            controlFIFOPath: root + "/Attempts/" + attemptName + "/lock-control.fifo"
        )
    } catch {
        close(attempts)
        close(current)
        throw error
    }
}

func removeDirectoryContents(_ descriptor: Int32) throws {
    guard let stream = fdopendir(dup(descriptor)) else {
        throw ValidationFailure("runner state could not be enumerated")
    }
    defer { closedir(stream) }
    while let entry = readdir(stream) {
        let name = withUnsafePointer(to: &entry.pointee.d_name) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
        }
        if name == "." || name == ".." { continue }
        var information = stat()
        guard fstatat(descriptor, name, &information, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw ValidationFailure("runner state changed during cleanup")
        }
        if (information.st_mode & S_IFMT) == S_IFDIR {
            let child = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else { throw ValidationFailure("runner state directory changed during cleanup") }
            try removeDirectoryContents(child)
            close(child)
            guard unlinkat(descriptor, name, AT_REMOVEDIR) == 0 else {
                throw ValidationFailure("runner state directory could not be removed")
            }
        } else {
            guard unlinkat(descriptor, name, 0) == 0 else {
                throw ValidationFailure("runner state file could not be removed")
            }
        }
    }
}

func readSealedRunnerConfig(configPath: String, expectedDigest: String) throws -> JSONObject {
    guard matches(expectedDigest, regex: digestPattern), configPath.hasPrefix("/tmp/") else {
        throw ValidationFailure("runner config identity is invalid")
    }
    let components = try relativeComponents(
        String(configPath.dropFirst("/tmp/".count)), at: "runner config"
    )
    guard components.count == 7,
          components[0] == "ios-template-verify",
          components[2].hasPrefix("issue-"),
          matches(components[3], regex: shaPattern),
          components[4] == "Attempts",
          components[5].hasPrefix("attempt-"),
          components[6] == "config.json" else {
        throw ValidationFailure("runner config path is not canonical")
    }
    let temporary = open("/tmp", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard temporary >= 0 else { throw ValidationFailure("trusted temporary root is unavailable") }
    defer { close(temporary) }
    let configData = try readBoundRegularFile(
        rootFileDescriptor: temporary,
        components: components,
        at: "runner config"
    )
    guard "sha256:\(sha256(data: configData))" == expectedDigest else {
        throw ValidationFailure("runner config digest changed")
    }
    let configParent = try openBoundDirectory(
        rootFileDescriptor: temporary,
        components: Array(components.dropLast()),
        at: "runner config parent"
    )
    defer { close(configParent) }
    let configFile = openat(configParent, components.last!, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard configFile >= 0 else { throw ValidationFailure("runner config is unavailable") }
    defer { close(configFile) }
    var configInfo = stat()
    guard fstat(configFile, &configInfo) == 0,
          configInfo.st_uid == getuid(), configInfo.st_nlink == 1,
          (configInfo.st_mode & 0o777) == S_IRUSR else {
        throw ValidationFailure("runner config is not sealed")
    }
    return try readJSONObject(data: configData, at: "runner config")
}

func runnerConfigValue(configPath: String, expectedDigest: String, keyPath: String) throws -> String {
    let config = try readSealedRunnerConfig(configPath: configPath, expectedDigest: expectedDigest)
    var value: Any = config
    for component in keyPath.split(separator: ".").map(String.init) {
        if let object = value as? JSONObject, let next = object[component] {
            value = next
        } else if let array = value as? [Any], let index = Int(component), array.indices.contains(index) {
            value = array[index]
        } else {
            throw ValidationFailure("runner config key is unavailable")
        }
    }
    guard let string = value as? String, !string.contains("\n"), !string.contains("\t") else {
        throw ValidationFailure("runner config value is not a safe scalar")
    }
    return string
}

func verifyRunnerXcode(
    configPath: String,
    expectedDigest: String,
    path: String,
    version: String,
    build: String
) throws {
    let config = try readSealedRunnerConfig(configPath: configPath, expectedDigest: expectedDigest)
    let expected = try validateXcodeIdentity(config["xcode"]!, at: "runner config xcode")
    guard expected.path == path, expected.version == version, expected.build == build else {
        throw ValidationFailure("resolved Xcode does not match the frozen matrix")
    }
}

func validatePNGData(_ data: Data) throws {
    let signature = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
    guard data.count >= 24, data.prefix(8) == signature,
          String(data: data[12..<16], encoding: .ascii) == "IHDR" else {
        throw ValidationFailure("screenshot is not a PNG")
    }
    let width = data[16..<20].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    let height = data[20..<24].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    guard width > 0, height > 0,
          let source = CGImageSourceCreateWithData(data as CFData, nil),
          CGImageSourceGetCount(source) == 1,
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
          image.width == Int(width), image.height == Int(height) else {
        throw ValidationFailure("screenshot PNG is not decodable")
    }
}

func validateRunnerPNG(source: String) throws {
    guard source.hasPrefix("/tmp/ios-template-verify/"), source.hasSuffix(".png") else {
        throw ValidationFailure("screenshot path is invalid")
    }
    let components = try relativeComponents(String(source.dropFirst("/tmp/".count)), at: "screenshot")
    let temporary = open("/tmp", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard temporary >= 0 else { throw ValidationFailure("trusted temporary root is unavailable") }
    defer { close(temporary) }
    let data = try readBoundRegularFile(rootFileDescriptor: temporary, components: components, at: "screenshot")
    try validatePNGData(data)
}

func cleanRunnerAttempt(configPath: String, expectedDigest: String) throws {
    let config = try readSealedRunnerConfig(configPath: configPath, expectedDigest: expectedDigest)
    let attemptPath = try requireString(config["attemptRoot"]!, at: "runner config attemptRoot")
    guard configPath == attemptPath + "/config.json", attemptPath.hasPrefix("/tmp/") else {
        throw ValidationFailure("runner attempt identity mismatch")
    }
    let components = try relativeComponents(String(attemptPath.dropFirst("/tmp/".count)), at: "runner attempt")
    let temporary = open("/tmp", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard temporary >= 0 else { throw ValidationFailure("trusted temporary root is unavailable") }
    defer { close(temporary) }
    let parent = try openBoundDirectory(rootFileDescriptor: temporary, components: Array(components.dropLast()), at: "runner attempt parent")
    defer { close(parent) }
    let attempt = openat(parent, components.last!, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard attempt >= 0 else { throw ValidationFailure("runner attempt is unavailable") }
    try removeDirectoryContents(attempt)
    close(attempt)
    guard unlinkat(parent, components.last!, AT_REMOVEDIR) == 0, fsync(parent) == 0 else {
        throw ValidationFailure("runner attempt could not be cleaned")
    }
}

func holdRunnerLock(configPath: String, expectedDigest: String) throws {
    let config = try readSealedRunnerConfig(configPath: configPath, expectedDigest: expectedDigest)
    let lockPath = try requireString(config["lockPath"]!, at: "runner config lockPath")
    guard lockPath.hasPrefix("/tmp/") else { throw ValidationFailure("runner lock path is invalid") }
    let components = try relativeComponents(String(lockPath.dropFirst("/tmp/".count)), at: "runner lock")
    let temporary = open("/tmp", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard temporary >= 0 else { throw ValidationFailure("trusted temporary root is unavailable") }
    defer { close(temporary) }
    let parent = try openBoundDirectory(rootFileDescriptor: temporary, components: Array(components.dropLast()), at: "runner lock parent")
    defer { close(parent) }
    let lockFile = openat(parent, components.last!, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
    guard lockFile >= 0 else { throw ValidationFailure("runner advisory lock is unavailable") }
    defer { close(lockFile) }
    var info = stat()
    guard fstat(lockFile, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
          info.st_uid == getuid(), info.st_nlink == 1,
          flock(lockFile, LOCK_EX | LOCK_NB) == 0 else {
        throw ValidationFailure("verification lock is already held")
    }
    FileHandle.standardOutput.write(Data("LOCKED\n".utf8))
    var byte: UInt8 = 0
    while true {
        let count = Darwin.read(STDIN_FILENO, &byte, 1)
        if count == 0 { break }
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { throw ValidationFailure("runner lock control failed") }
    }
    guard flock(lockFile, LOCK_UN) == 0 else {
        throw ValidationFailure("verification lock release failed")
    }
}

func findBuiltApplication(derivedDataPath: String, bundleIdentifier: String) throws -> String {
    guard matches(bundleIdentifier, regex: bundleIdentifierPattern),
          derivedDataPath.hasPrefix("/tmp/ios-template-verify/"),
          derivedDataPath.hasSuffix("/DerivedData") else {
        throw ValidationFailure("built application lookup inputs are invalid")
    }
    let relative = String(derivedDataPath.dropFirst("/tmp/".count))
    let components = try relativeComponents(relative, at: "DerivedData")
    let temporary = open("/tmp", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard temporary >= 0 else { throw ValidationFailure("trusted temporary root is unavailable") }
    defer { close(temporary) }
    let derived = try openBoundDirectory(rootFileDescriptor: temporary, components: components, at: "DerivedData")
    defer { close(derived) }
    var derivedInfo = stat()
    guard fstat(derived, &derivedInfo) == 0, derivedInfo.st_uid == getuid() else {
        throw ValidationFailure("DerivedData is not owned by the current user")
    }
    let products = try openBoundDirectory(
        rootFileDescriptor: derived,
        components: ["Build", "Products"],
        at: "DerivedData Build products"
    )
    defer { close(products) }

    var matches: [String] = []
    func scan(_ directory: Int32, relativePath: String) throws {
        guard let stream = fdopendir(dup(directory)) else {
            throw ValidationFailure("Build products could not be enumerated")
        }
        defer { closedir(stream) }
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            var information = stat()
            guard fstatat(directory, name, &information, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw ValidationFailure("Build products changed during enumeration")
            }
            if (information.st_mode & S_IFMT) == S_IFLNK {
                throw ValidationFailure("Build products contain a symbolic link")
            }
            guard (information.st_mode & S_IFMT) == S_IFDIR else { continue }
            let child = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else { throw ValidationFailure("Build product directory changed") }
            defer { close(child) }
            let childPath = relativePath.isEmpty ? name : relativePath + "/" + name
            if name.hasSuffix(".app") {
                let plistData = try readBoundRegularFile(
                    rootFileDescriptor: child,
                    components: ["Info.plist"],
                    at: "built application Info.plist"
                )
                let plistValue = try PropertyListSerialization.propertyList(from: plistData, options: [], format: nil)
                guard let plist = plistValue as? [String: Any] else {
                    throw ValidationFailure("built application Info.plist is invalid")
                }
                if plist["CFBundleIdentifier"] as? String == bundleIdentifier {
                    guard information.st_uid == getuid() else {
                        throw ValidationFailure("built application is not owned by the current user")
                    }
                    matches.append(derivedDataPath + "/Build/Products/" + childPath)
                }
            } else {
                try scan(child, relativePath: childPath)
            }
        }
    }
    try scan(products, relativePath: "")
    guard matches.count == 1 else {
        throw ValidationFailure("exactly one contained built application must match the bundle identifier")
    }
    return matches[0]
}

func ensureOwnedDirectory(
    parent: Int32,
    name: String,
    privatePermissions: Bool,
    label: String
) throws -> Int32 {
    let mode: mode_t = privatePermissions ? S_IRWXU : (S_IRWXU | S_IRGRP | S_IXGRP | S_IROTH | S_IXOTH)
    if mkdirat(parent, name, mode) != 0, errno != EEXIST {
        throw ValidationFailure("\(label) could not be created")
    }
    let descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw ValidationFailure("\(label) is unavailable or a symbolic link") }
    var information = stat()
    guard fstat(descriptor, &information) == 0,
          (information.st_mode & S_IFMT) == S_IFDIR,
          information.st_uid == getuid() else {
        close(descriptor)
        throw ValidationFailure("\(label) is not an owned directory")
    }
    if privatePermissions, (information.st_mode & 0o777) != S_IRWXU {
        guard fchmod(descriptor, S_IRWXU) == 0 else {
            close(descriptor)
            throw ValidationFailure("\(label) could not be made private")
        }
    }
    return descriptor
}

struct RunnerFinalizeOptions {
    let issue: Int
    let expectedBase: String
    let expectedHead: String
    let draftPath: String
    let visualPath: String
}

struct RunnerDraftOptions {
    let configPath: String
    let configDigest: String
    let issue: Int
    let expectedBase: String
    let expectedHead: String
    let scheme: String
    let derivedData: String
    let buildResult: String
    let testResult: String
    let passed: Int
    let failed: Int
    let skipped: Int
}

func publishRunnerDraft(_ options: RunnerDraftOptions) throws -> String {
    guard options.issue > 0, matches(options.expectedBase, regex: shaPattern),
          matches(options.expectedHead, regex: shaPattern), options.expectedBase != options.expectedHead,
          options.scheme.range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil,
          options.passed > 0, options.failed == 0, options.skipped == 0 else {
        throw ValidationFailure("runner draft inputs are invalid")
    }
    let config = try readSealedRunnerConfig(configPath: options.configPath, expectedDigest: options.configDigest)
    let repository = try validateTrustedRepository(expectedBase: options.expectedBase, expectedHead: options.expectedHead)
    defer { close(repository.rootFileDescriptor) }
    guard try requireString(config["repositoryRoot"]!, at: "runner config repositoryRoot") == repository.rootPath else {
        throw ValidationFailure("runner config repository identity mismatch")
    }
    let contractPath = try requireString(config["contractPath"]!, at: "runner config contractPath")
    let matrixPath = try requireString(config["matrixPath"]!, at: "runner config matrixPath")
    let contractDigest = try requireString(config["contractDigest"]!, at: "runner config contractDigest")
    let matrixDigest = try requireString(config["matrixDigest"]!, at: "runner config matrixDigest")
    try verifyRunnerInputs(
        options: RunnerSnapshotOptions(
            issue: options.issue, expectedBase: options.expectedBase, expectedHead: options.expectedHead,
            issueContract: contractPath, matrix: matrixPath
        ),
        contractDigest: contractDigest,
        matrixDigest: matrixDigest
    )
    let attemptRoot = try requireString(config["attemptRoot"]!, at: "runner config attemptRoot")
    guard options.configPath == attemptRoot + "/config.json",
          options.derivedData == attemptRoot + "/DerivedData",
          options.buildResult == attemptRoot + "/Build.xcresult",
          options.testResult == attemptRoot + "/Tests.xcresult" else {
        throw ValidationFailure("runner draft workspace paths are invalid")
    }
    let configuredCases = try requireArray(config["cases"]!, at: "runner config cases")
    guard configuredCases.count == 4 else { throw ValidationFailure("runner config cases are invalid") }
    var draftCases: [[String: Any]] = []
    for value in configuredCases {
        let entry = try requireObject(value, at: "runner config case")
        let id = try requireString(entry["id"]!, at: "runner config case id")
        let action = try requireString(entry["action"]!, at: "runner config case action")
        let actionValue = try requireString(entry["value"]!, at: "runner config case value")
        draftCases.append([
            "id": id,
            "status": "passed",
            "screenshot": "\(id)/screenshot.png",
            "mechanicalCheck": action == "testIdentifier" ? "test:\(actionValue)" : "assertion:launch-succeeded"
        ])
    }
    let configuredMappings = try requireArray(config["acceptanceMappings"]!, at: "runner config acceptanceMappings")
    let executionMappings: [[String: Any]] = try configuredMappings.map { value in
        let mapping = try requireObject(value, at: "runner config acceptance mapping")
        let id = try requireString(mapping["id"]!, at: "runner config acceptance ID")
        let checks = try requireStringArray(mapping["checks"]!, at: "runner config acceptance checks")
            .filter { !$0.hasPrefix("visual:") }
        return ["id": id, "evidence": checks]
    }
    let completedAt = ISO8601DateFormatter().string(from: Date())
    let draft: [String: Any] = [
        "schemaVersion": 1, "status": "awaiting-visual-review", "issue": options.issue,
        "baseSha": options.expectedBase, "headSha": options.expectedHead,
        "issueContract": ["path": contractPath, "digest": contractDigest],
        "matrixFile": matrixPath, "matrixDigest": matrixDigest,
        "executionRoute": "xcodebuild-simctl", "xcode": config["xcode"]!,
        "build": ["status": "passed", "scheme": options.scheme, "warningsAdded": 0],
        "tests": ["status": "passed", "passed": options.passed, "failed": 0, "skipped": 0],
        "cases": draftCases, "acceptanceEvidence": executionMappings,
        "workspaceArtifacts": [
            "derivedDataPath": options.derivedData,
            "buildResultBundlePath": options.buildResult,
            "testResultBundlePath": options.testResult
        ],
        "executionCompletedAt": completedAt
    ]
    let draftData = try JSONSerialization.data(withJSONObject: draft, options: [.prettyPrinted, .sortedKeys]) + Data("\n".utf8)
    let currentHead = try runGitString(["rev-parse", "HEAD"], failure: "current Git Head unavailable before draft publication")
    let currentStatus = try runGitProcess(["status", "--porcelain", "--untracked-files=all"])
    guard currentHead == options.expectedHead, currentStatus.status == 0, currentStatus.stdout.isEmpty else {
        throw ValidationFailure("working tree changed before draft publication")
    }
    let evidenceComponents = [".artifacts", "issues", String(options.issue), options.expectedHead]
    let evidenceDirectory = try openBoundDirectory(
        rootFileDescriptor: repository.rootFileDescriptor, components: evidenceComponents, at: "evidence directory"
    )
    defer { close(evidenceDirectory) }
    var screenshotDirectories: [Int32] = []
    var screenshotData: [Data] = []
    defer { screenshotDirectories.forEach { close($0) } }
    for value in configuredCases {
        let entry = try requireObject(value, at: "runner config case")
        let id = try requireString(entry["id"]!, at: "runner config case id")
        let sourcePath = attemptRoot + "/Screenshots/\(id).png"
        let sourceComponents = try relativeComponents(String(sourcePath.dropFirst("/tmp/".count)), at: "attempt screenshot")
        let temporary = open("/tmp", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard temporary >= 0 else { throw ValidationFailure("trusted temporary root is unavailable") }
        let data: Data
        do {
            data = try readBoundRegularFile(rootFileDescriptor: temporary, components: sourceComponents, at: "attempt screenshot")
            close(temporary)
        } catch {
            close(temporary)
            throw error
        }
        try validatePNGData(data)
        let caseDirectory = try ensureOwnedDirectory(
            parent: evidenceDirectory, name: id, privatePermissions: true, label: "case evidence directory"
        )
        var existing = stat()
        guard fstatat(caseDirectory, "screenshot.png", &existing, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else {
            close(caseDirectory)
            throw ValidationFailure("canonical screenshot already exists")
        }
        screenshotDirectories.append(caseDirectory)
        screenshotData.append(data)
    }
    var publishedScreenshotCount = 0
    do {
        for index in screenshotDirectories.indices {
            try publishGeneratedData(
                directoryFileDescriptor: screenshotDirectories[index],
                canonicalName: "screenshot.png",
                temporaryPrefix: ".screenshot-candidate",
                data: screenshotData[index]
            )
            publishedScreenshotCount += 1
        }
        try publishGeneratedData(
            directoryFileDescriptor: evidenceDirectory,
            canonicalName: "verify-draft.json",
            temporaryPrefix: ".verify-draft-candidate",
            data: draftData
        )
    } catch {
        for index in 0..<publishedScreenshotCount {
            _ = unlinkat(screenshotDirectories[index], "screenshot.png", 0)
            _ = fsync(screenshotDirectories[index])
        }
        throw error
    }
    return repository.rootPath + "/" + (evidenceComponents + ["verify-draft.json"]).joined(separator: "/")
}

func finalizeRunnerEvidence(_ options: RunnerFinalizeOptions) throws -> String {
    let repository = try validateTrustedRepository(
        expectedBase: options.expectedBase, expectedHead: options.expectedHead
    )
    defer { close(repository.rootFileDescriptor) }
    let status = try runGitProcess(["status", "--porcelain", "--untracked-files=all"])
    guard status.status == 0, status.stdout.isEmpty else {
        throw ValidationFailure("working tree changed before final publication")
    }
    let evidenceComponents = [".artifacts", "issues", String(options.issue), options.expectedHead]
    let expectedDraft = (evidenceComponents + ["verify-draft.json"]).joined(separator: "/")
    let expectedVisual = (evidenceComponents + ["visual-result.json"]).joined(separator: "/")
    guard options.draftPath == expectedDraft, options.visualPath == expectedVisual else {
        throw ValidationFailure("draft and visual result must use canonical paths")
    }
    let draftData = try readBoundRegularFile(
        rootFileDescriptor: repository.rootFileDescriptor,
        components: evidenceComponents + ["verify-draft.json"], at: "draft"
    )
    let visualData = try readBoundRegularFile(
        rootFileDescriptor: repository.rootFileDescriptor,
        components: evidenceComponents + ["visual-result.json"], at: "visual result"
    )
    let draft = try readJSONObject(data: draftData, at: "draft")
    let visual = try readJSONObject(data: visualData, at: "visual result")
    try requireExactKeys(draft, [
        "schemaVersion", "status", "issue", "baseSha", "headSha", "issueContract", "matrixFile",
        "matrixDigest", "executionRoute", "xcode", "build", "tests", "cases", "acceptanceEvidence",
        "workspaceArtifacts", "executionCompletedAt"
    ], at: "draft")
    guard try requireInteger(draft["schemaVersion"]!, at: "draft schemaVersion") == 1,
          try requireString(draft["status"]!, at: "draft status") == "awaiting-visual-review",
          try requireInteger(draft["issue"]!, at: "draft issue") == options.issue,
          try requireString(draft["baseSha"]!, at: "draft baseSha") == options.expectedBase,
          try requireString(draft["headSha"]!, at: "draft headSha") == options.expectedHead else {
        throw ValidationFailure("draft identity does not match current Git range")
    }
    let contractReference = try requireObject(draft["issueContract"]!, at: "draft issueContract")
    let contract = try validateIssueContract(reference: contractReference, issue: options.issue, repository: repository)
    guard let verification = contract.verification else {
        throw ValidationFailure("canonical contract has no verification contract")
    }
    let matrixPath = try requireString(draft["matrixFile"]!, at: "draft matrixFile")
    let matrixComponents = try relativeComponents(matrixPath, at: "draft matrixFile")
    let matrixData = try readBoundRegularFile(
        rootFileDescriptor: repository.rootFileDescriptor, components: matrixComponents, at: "draft matrixFile"
    )
    try validateDigest(draft["matrixDigest"]!, data: matrixData, at: "draft matrixDigest")
    let matrix = try validateMatrix(data: matrixData, recordedPath: matrixPath)
    guard try requireString(draft["executionRoute"]!, at: "draft executionRoute") == "xcodebuild-simctl",
          try validateXcodeIdentity(draft["xcode"]!, at: "draft xcode") == matrix.xcode else {
        throw ValidationFailure("draft execution identity is invalid")
    }
    try validateBuild(draft["build"]!, documentationOnly: false)
    try validateTests(draft["tests"]!, documentationOnly: false)
    let draftCases = try requireArray(draft["cases"]!, at: "draft cases")
    guard draftCases.count == 4 else { throw ValidationFailure("draft must contain exact four cases") }
    for (index, value) in draftCases.enumerated() {
        let entry = try requireObject(value, at: "draft case")
        try requireExactKeys(entry, ["id", "status", "screenshot", "mechanicalCheck"], at: "draft case")
        let expectedCase = verification.cases[index]
        let expectedCheck = expectedCase.action == "testIdentifier"
            ? "test:\(expectedCase.value)" : "assertion:launch-succeeded"
        guard try requireString(entry["id"]!, at: "draft case id") == matrix.caseIDs[index],
              try requireString(entry["status"]!, at: "draft case status") == "passed",
              try requireString(entry["screenshot"]!, at: "draft case screenshot") == "\(matrix.caseIDs[index])/screenshot.png",
              try requireString(entry["mechanicalCheck"]!, at: "draft mechanicalCheck") == expectedCheck else {
            throw ValidationFailure("draft mechanical checks do not match the canonical contract")
        }
    }
    let acceptance = try requireArray(draft["acceptanceEvidence"]!, at: "draft acceptanceEvidence")
    guard acceptance.count == contract.acceptanceIDs.count else {
        throw ValidationFailure("draft acceptance mappings do not match the canonical contract")
    }
    for (index, value) in acceptance.enumerated() {
        let entry = try requireObject(value, at: "draft acceptance evidence")
        try requireExactKeys(entry, ["id", "evidence"], at: "draft acceptance evidence")
        let executionChecks = verification.acceptanceMappings[index].filter { !$0.hasPrefix("visual:") }
        guard try requireString(entry["id"]!, at: "draft acceptance ID") == contract.acceptanceIDs[index],
              try requireStringArray(entry["evidence"]!, at: "draft acceptance evidence") == executionChecks else {
            throw ValidationFailure("draft acceptance mappings do not match the canonical contract")
        }
    }
    let artifacts = try requireObject(draft["workspaceArtifacts"]!, at: "draft workspaceArtifacts")
    try requireExactKeys(artifacts, ["derivedDataPath", "buildResultBundlePath", "testResultBundlePath"], at: "draft workspaceArtifacts")
    let rootDigest = sha256(data: Data(repository.rootPath.utf8))
    let worktreeName = URL(fileURLWithPath: repository.rootPath).lastPathComponent
        .replacingOccurrences(of: "[^A-Za-z0-9_.-]", with: "-", options: .regularExpression)
    let workspace = "/tmp/ios-template-verify/\(worktreeName)-\(rootDigest)/issue-\(options.issue)/\(options.expectedHead)"
    let derived = try requireString(artifacts["derivedDataPath"]!, at: "draft derivedDataPath")
    let prefix = workspace + "/Attempts/"
    guard derived.hasPrefix(prefix), derived.hasSuffix("/DerivedData") else {
        throw ValidationFailure("draft workspaceArtifacts do not match the current physical worktree")
    }
    let attempt = String(derived.dropFirst(prefix.count).dropLast("/DerivedData".count))
    guard attempt.range(of: "^attempt-[0-9a-f-]+$", options: .regularExpression) != nil,
          try requireString(artifacts["buildResultBundlePath"]!, at: "draft buildResultBundlePath") == "\(prefix)\(attempt)/Build.xcresult",
          try requireString(artifacts["testResultBundlePath"]!, at: "draft testResultBundlePath") == "\(prefix)\(attempt)/Tests.xcresult" else {
        throw ValidationFailure("draft workspaceArtifacts do not match the current physical worktree")
    }
    let executionCompleted = try requireISO8601Date(draft["executionCompletedAt"]!, at: "draft executionCompletedAt")

    try requireExactKeys(visual, ["schemaVersion", "status", "issue", "headSha", "draft", "cases", "findings", "reviewedAt"], at: "visual result")
    guard try requireInteger(visual["schemaVersion"]!, at: "visual schemaVersion") == 1,
          try requireString(visual["status"]!, at: "visual status") == "approved",
          try requireInteger(visual["issue"]!, at: "visual issue") == options.issue,
          try requireString(visual["headSha"]!, at: "visual headSha") == options.expectedHead,
          try requireStringArray(visual["findings"]!, at: "visual findings").isEmpty else {
        throw ValidationFailure("visual result is not approved")
    }
    let visualDraft = try requireObject(visual["draft"]!, at: "visual draft")
    try requireExactKeys(visualDraft, ["path", "digest"], at: "visual draft")
    guard try requireString(visualDraft["path"]!, at: "visual draft path") == options.draftPath,
          try requireString(visualDraft["digest"]!, at: "visual draft digest") == "sha256:\(sha256(data: draftData))" else {
        throw ValidationFailure("visual draft digest mismatch")
    }
    let visualCases = try requireArray(visual["cases"]!, at: "visual cases")
    guard visualCases.count == 4 else { throw ValidationFailure("visual result must contain exact four cases") }
    for (index, value) in visualCases.enumerated() {
        let entry = try requireObject(value, at: "visual case")
        try requireExactKeys(entry, ["id", "status", "screenshot", "findings"], at: "visual case")
        guard try requireString(entry["id"]!, at: "visual case id") == matrix.caseIDs[index],
              try requireString(entry["status"]!, at: "visual case status") == "approved",
              try requireString(entry["screenshot"]!, at: "visual screenshot") == "\(matrix.caseIDs[index])/screenshot.png",
              try requireStringArray(entry["findings"]!, at: "visual case findings").isEmpty else {
            throw ValidationFailure("visual result cases mismatch or contain findings")
        }
    }
    let reviewedAt = try requireISO8601Date(visual["reviewedAt"]!, at: "visual reviewedAt")
    guard reviewedAt >= executionCompleted, reviewedAt <= Date().addingTimeInterval(300) else {
        throw ValidationFailure("visual review timestamp is invalid")
    }
    let finalCases = matrix.caseIDs.map { ["id": $0, "status": "passed", "screenshot": "\($0)/screenshot.png"] }
    let finalAcceptance: [[String: Any]] = contract.acceptanceIDs.enumerated().map { index, id in
        ["id": id, "status": "passed", "evidence": verification.acceptanceMappings[index]]
    }
    let final: [String: Any] = [
        "schemaVersion": 1, "status": "passed", "changeClassification": "application-code", "reason": NSNull(),
        "issue": options.issue, "baseSha": options.expectedBase, "headSha": options.expectedHead,
        "issueContract": contractReference, "matrixFile": matrixPath, "matrixDigest": draft["matrixDigest"]!,
        "executionRoute": "xcodebuild-simctl", "xcode": draft["xcode"]!, "build": draft["build"]!,
        "tests": draft["tests"]!, "cases": finalCases,
        "visualEvaluation": ["status": "passed", "findings": []],
        "acceptanceEvidence": finalAcceptance,
        "completedAt": try requireString(visual["reviewedAt"]!, at: "visual reviewedAt")
    ]
    let finalData = try JSONSerialization.data(withJSONObject: final, options: [.prettyPrinted, .sortedKeys]) + Data("\n".utf8)
    let evidenceDirectory = try openBoundDirectory(
        rootFileDescriptor: repository.rootFileDescriptor, components: evidenceComponents, at: "evidence directory"
    )
    defer { close(evidenceDirectory) }
    let candidateName = ".verify-candidate-\(UUID().uuidString.lowercased())"
    try writeExclusiveFile(directoryFileDescriptor: evidenceDirectory, name: candidateName, data: finalData, permissions: S_IRUSR)
    let candidateFD = openat(evidenceDirectory, candidateName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard candidateFD >= 0 else { throw ValidationFailure("verify.json candidate could not be retained") }
    defer {
        heldValidatedCandidateFileDescriptor = nil
        close(candidateFD)
        _ = unlinkat(evidenceDirectory, candidateName, 0)
    }
    heldValidatedCandidateFileDescriptor = candidateFD
    let finalPath = repository.rootPath + "/" + (evidenceComponents + ["verify.json"]).joined(separator: "/")
    let candidatePath = repository.rootPath + "/" + (evidenceComponents + [candidateName]).joined(separator: "/")
    try validate(options: Options(
        file: finalPath, candidateFile: candidatePath, expectedIssue: options.issue,
        expectedBase: options.expectedBase, expectedHead: options.expectedHead
    ))
    return finalPath
}

func parseOptions(_ arguments: [String]) throws -> Options {
    var file: String?
    var expectedIssue: Int?
    var expectedBase: String?
    var expectedHead: String?
    var candidateFile: String?
    var index = 0
    var seen = Set<String>()
    let allowed = ["--file", "--candidate-file", "--expected-issue", "--expected-base", "--expected-head"]
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
        case "--candidate-file":
            guard !value.isEmpty else { throw ValidationFailure("--candidate-file must not be empty") }
            candidateFile = value
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
    return Options(
        file: file,
        candidateFile: candidateFile,
        expectedIssue: expectedIssue,
        expectedBase: expectedBase,
        expectedHead: expectedHead
    )
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
    let candidateName: String?
    let sourceComponents: [String]
    if let candidateFile = options.candidateFile {
        let candidateURL = URL(fileURLWithPath: absoluteStandardizedPath(candidateFile))
        let evidenceDirectoryPath = repository.rootPath + "/" + evidenceComponents.dropLast().joined(separator: "/")
        guard candidateURL.deletingLastPathComponent().path == evidenceDirectoryPath,
              candidateURL.lastPathComponent.range(of: "^\\.verify-candidate-[A-Za-z0-9-]+$", options: .regularExpression) != nil else {
            throw ValidationFailure("--candidate-file must be an exclusive candidate in the canonical evidence directory")
        }
        candidateName = candidateURL.lastPathComponent
        sourceComponents = Array(evidenceComponents.dropLast()) + [candidateURL.lastPathComponent]
    } else {
        candidateName = nil
        sourceComponents = evidenceComponents
    }
    let evidenceData = try readBoundRegularFile(
        rootFileDescriptor: repository.rootFileDescriptor,
        components: sourceComponents,
        at: candidateName == nil ? "verify.json" : "verify.json candidate"
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
            root["acceptanceEvidence"]!, contractIDs: contract.acceptanceIDs, documentationOnly: false,
            expectedMappings: contract.verification?.acceptanceMappings
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
    if let candidateName {
        try publishValidatedCandidate(
            repository: repository,
            evidenceDirectoryComponents: Array(evidenceComponents.dropLast()),
            candidateName: candidateName
        )
    }
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments.first == "--runner-snapshot" {
        let options = try parseRunnerSnapshotOptions(Array(arguments.dropFirst()))
        FileHandle.standardOutput.write(try runnerSnapshot(options: options))
        FileHandle.standardOutput.write(Data("\n".utf8))
    } else if arguments.first == "--runner-check-inputs" {
        guard arguments.count == 15 else { throw ValidationFailure("invalid runner input-check arguments") }
        var values: [String: String] = [:]
        var index = 1
        while index < arguments.count {
            guard values[arguments[index]] == nil else { throw ValidationFailure("duplicate runner input-check argument") }
            values[arguments[index]] = arguments[index + 1]
            index += 2
        }
        let snapshotArguments = [
            "--issue", values["--issue"] ?? "",
            "--expected-base", values["--expected-base"] ?? "",
            "--expected-head", values["--expected-head"] ?? "",
            "--issue-contract", values["--issue-contract"] ?? "",
            "--matrix", values["--matrix"] ?? ""
        ]
        let options = try parseRunnerSnapshotOptions(snapshotArguments)
        guard let contractDigest = values["--contract-digest"], let matrixDigest = values["--matrix-digest"], values.count == 7 else {
            throw ValidationFailure("invalid runner input-check arguments")
        }
        try verifyRunnerInputs(options: options, contractDigest: contractDigest, matrixDigest: matrixDigest)
    } else if arguments.first == "--runner-config" {
        guard arguments.count >= 6, arguments[1] == "--config", arguments[3] == "--digest" else {
            throw ValidationFailure("invalid runner config arguments")
        }
        if arguments.count == 7, arguments[5] == "--get" {
            print(try runnerConfigValue(configPath: arguments[2], expectedDigest: arguments[4], keyPath: arguments[6]))
        } else if arguments.count == 6, arguments[5] == "--check" {
            _ = try readSealedRunnerConfig(configPath: arguments[2], expectedDigest: arguments[4])
        } else {
            throw ValidationFailure("invalid runner config operation")
        }
    } else if arguments.first == "--runner-lock-holder" {
        guard arguments.count == 5, arguments[1] == "--config", arguments[3] == "--digest" else {
            throw ValidationFailure("invalid runner lock-holder arguments")
        }
        try holdRunnerLock(configPath: arguments[2], expectedDigest: arguments[4])
    } else if arguments.first == "--runner-clean-attempt" {
        guard arguments.count == 5, arguments[1] == "--config", arguments[3] == "--digest" else {
            throw ValidationFailure("invalid runner cleanup arguments")
        }
        try cleanRunnerAttempt(configPath: arguments[2], expectedDigest: arguments[4])
    } else if arguments.first == "--runner-verify-xcode" {
        guard arguments.count == 11, arguments[1] == "--config", arguments[3] == "--digest",
              arguments[5] == "--path", arguments[7] == "--version", arguments[9] == "--build" else {
            throw ValidationFailure("invalid runner Xcode arguments")
        }
        try verifyRunnerXcode(
            configPath: arguments[2], expectedDigest: arguments[4],
            path: arguments[6], version: arguments[8], build: arguments[10]
        )
    } else if arguments.first == "--runner-validate-png" {
        guard arguments.count == 3, arguments[1] == "--source" else {
            throw ValidationFailure("invalid runner PNG arguments")
        }
        try validateRunnerPNG(source: arguments[2])
    } else if arguments.first == "--runner-finalize" {
        guard arguments.count == 11 else { throw ValidationFailure("invalid runner finalization arguments") }
        var values: [String: String] = [:]
        var index = 1
        while index < arguments.count {
            guard values[arguments[index]] == nil else { throw ValidationFailure("duplicate runner finalization argument") }
            values[arguments[index]] = arguments[index + 1]
            index += 2
        }
        guard let issueText = values["--issue"], let issue = Int(issueText), issue > 0,
              let expectedBase = values["--expected-base"], let expectedHead = values["--expected-head"],
              let draft = values["--draft"], let visual = values["--visual-result"], values.count == 5 else {
            throw ValidationFailure("invalid runner finalization arguments")
        }
        print(try finalizeRunnerEvidence(RunnerFinalizeOptions(
            issue: issue, expectedBase: expectedBase, expectedHead: expectedHead,
            draftPath: draft, visualPath: visual
        )))
    } else if arguments.first == "--runner-publish-draft" {
        guard arguments.count == 25 else { throw ValidationFailure("invalid runner draft arguments") }
        var values: [String: String] = [:]
        var index = 1
        while index < arguments.count {
            guard values[arguments[index]] == nil else { throw ValidationFailure("duplicate runner draft argument") }
            values[arguments[index]] = arguments[index + 1]
            index += 2
        }
        guard let config = values["--config"], let digest = values["--digest"],
              let issueText = values["--issue"], let issue = Int(issueText),
              let expectedBase = values["--expected-base"], let expectedHead = values["--expected-head"],
              let scheme = values["--scheme"], let derivedData = values["--derived-data"],
              let buildResult = values["--build-result"], let testResult = values["--test-result"],
              let passedText = values["--passed"], let passed = Int(passedText),
              let failedText = values["--failed"], let failed = Int(failedText),
              let skippedText = values["--skipped"], let skipped = Int(skippedText), values.count == 12 else {
            throw ValidationFailure("invalid runner draft arguments")
        }
        print(try publishRunnerDraft(RunnerDraftOptions(
            configPath: config, configDigest: digest, issue: issue,
            expectedBase: expectedBase, expectedHead: expectedHead, scheme: scheme,
            derivedData: derivedData, buildResult: buildResult, testResult: testResult,
            passed: passed, failed: failed, skipped: skipped
        )))
    } else if arguments.first == "--runner-find-app" {
        guard arguments.count == 5, arguments[1] == "--derived-data", arguments[3] == "--bundle-identifier" else {
            throw ValidationFailure("invalid built application lookup arguments")
        }
        print(try findBuiltApplication(derivedDataPath: arguments[2], bundleIdentifier: arguments[4]))
    } else {
        let options = try parseOptions(arguments)
        try validate(options: options)
        print("verification evidence is valid")
    }
} catch let failure as ValidationFailure {
    FileHandle.standardError.write(Data("verify.json validation failed: \(failure.description)\n".utf8))
    exit(1)
} catch {
    FileHandle.standardError.write(Data("verify.json validation failed: unexpected error\n".utf8))
    exit(1)
}
