import Foundation

struct Runtime: Codable {
    let identifier: String
    let version: String
    let isAvailable: Bool
}

struct RuntimeList: Codable {
    let runtimes: [Runtime]
}

struct DeviceType: Codable {
    let identifier: String
    let name: String
    let productFamily: String?
}

struct DeviceTypeList: Codable {
    let devicetypes: [DeviceType]
}

struct Device: Codable {
    let udid: String?
    let name: String?
    let state: String?
    let isAvailable: Bool?
    let availability: String?
    let deviceTypeIdentifier: String?
}

struct DeviceList: Codable {
    let devices: [String: [Device]]
}

struct RuntimeReference: Codable, Equatable {
    let identifier: String
    let version: String
}

struct DeviceTypeReference: Codable, Equatable {
    let identifier: String
    let name: String
}

struct MatrixCase: Codable, Equatable {
    let id: String
    let family: String
    let deviceType: DeviceTypeReference
    let locale: String
    let language: String
}

struct Matrix: Codable {
    let schemaVersion: Int
    let scope: String?
    let batchId: String
    let resolvedAt: String
    let runtime: RuntimeReference
    let cases: [MatrixCase]
}

struct Arguments {
    let runtimesPath: String
    let deviceTypesPath: String
    let devicesPath: String
    let batchID: String
    let resolvedAt: String
    let scope: String
    let caseIDs: [String]
}

enum ResolverError: Error {
    case usage
    case unreadableInput(String)
    case noAvailableIOSRuntime
    case invalidRuntimeVersion(String)
    case missingRuntimeDevices(String)
    case noIPhonePro([String])
    case noIPadAir([String])

    var message: String {
        switch self {
        case .usage:
            return "usage: resolve-simulator-matrix.swift --runtimes <path> --device-types <path> --devices <path> --batch-id <id> [--resolved-at <ISO-8601 timestamp>] [--scope iphone-ja|targeted|full] [--case-ids id,id]"
        case .unreadableInput(let path):
            return "blocked:environment: unable to decode simctl JSON input: \(path)"
        case .noAvailableIOSRuntime:
            return "blocked:environment: no available iOS Runtime"
        case .invalidRuntimeVersion(let version):
            return "blocked:environment: invalid available iOS Runtime version: \(version)"
        case .missingRuntimeDevices(let runtimeID):
            return "blocked:environment: devices.json has no provenance entry for selected Runtime: \(runtimeID)"
        case .noIPhonePro(let candidates):
            return "blocked:environment: no matching iPhone Pro Device Type; candidates: \(candidates.joined(separator: ", "))"
        case .noIPadAir(let candidates):
            return "blocked:environment: no matching iPad Air Device Type; candidates: \(candidates.joined(separator: ", "))"
        }
    }
}

func parseArguments(_ arguments: [String]) throws -> Arguments {
    guard arguments.count >= 8, arguments.count <= 14, arguments.count.isMultiple(of: 2) else {
        throw ResolverError.usage
    }

    var values: [String: String] = [:]
    var index = 0
    while index < arguments.count {
        let flag = arguments[index]
        let value = arguments[index + 1]
        guard ["--runtimes", "--device-types", "--devices", "--batch-id", "--resolved-at", "--scope", "--case-ids"].contains(flag),
              values[flag] == nil,
              !value.isEmpty else {
            throw ResolverError.usage
        }
        values[flag] = value
        index += 2
    }

    guard let runtimesPath = values["--runtimes"],
          let deviceTypesPath = values["--device-types"],
          let devicesPath = values["--devices"],
          let batchID = values["--batch-id"] else {
        throw ResolverError.usage
    }

    let resolvedAt = values["--resolved-at"] ?? ISO8601DateFormatter().string(from: Date())
    let scope = values["--scope"] ?? "full"
    guard ["iphone-ja", "targeted", "full"].contains(scope) else { throw ResolverError.usage }
    let fullIDs = ["iphone-en", "iphone-ja", "ipad-en", "ipad-ja"]
    let caseIDs: [String]
    if scope == "targeted" {
        guard let raw = values["--case-ids"] else { throw ResolverError.usage }
        caseIDs = raw.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard !caseIDs.isEmpty, Set(caseIDs).count == caseIDs.count,
              caseIDs.allSatisfy(fullIDs.contains),
              caseIDs == fullIDs.filter(caseIDs.contains) else { throw ResolverError.usage }
    } else {
        guard values["--case-ids"] == nil else { throw ResolverError.usage }
        caseIDs = scope == "iphone-ja" ? ["iphone-ja"] : fullIDs
    }
    return Arguments(
        runtimesPath: runtimesPath,
        deviceTypesPath: deviceTypesPath,
        devicesPath: devicesPath,
        batchID: batchID,
        resolvedAt: resolvedAt,
        scope: scope,
        caseIDs: caseIDs
    )
}

func decode<T: Decodable>(_ type: T.Type, from path: String) throws -> T {
    guard let data = FileManager.default.contents(atPath: path),
          let value = try? JSONDecoder().decode(type, from: data) else {
        throw ResolverError.unreadableInput(path)
    }
    return value
}

func numericDotVersionComponents(in value: String) -> [Int]? {
    let pattern = #"^[0-9]+(?:\.[0-9]+)*$"#
    guard let expression = try? NSRegularExpression(pattern: pattern) else {
        return nil
    }
    let range = NSRange(value.startIndex..<value.endIndex, in: value)
    guard expression.firstMatch(in: value, range: range)?.range == range else {
        return nil
    }
    let components = value.split(separator: ".", omittingEmptySubsequences: false)
    guard !components.isEmpty else { return nil }
    let parsed = components.compactMap { Int($0) }
    return parsed.count == components.count ? parsed : nil
}

func compareSemanticVersions(_ left: [Int], _ right: [Int]) -> ComparisonResult {
    let count = max(left.count, right.count)
    for index in 0..<count {
        let leftComponent = index < left.count ? left[index] : 0
        let rightComponent = index < right.count ? right[index] : 0
        if leftComponent != rightComponent {
            return leftComponent < rightComponent ? .orderedAscending : .orderedDescending
        }
    }
    return .orderedSame
}

func newestRuntime(from runtimes: [Runtime]) throws -> Runtime {
    let iOSRuntimePrefix = "com.apple.CoreSimulator.SimRuntime.iOS-"
    let available = runtimes.filter { $0.isAvailable && $0.identifier.hasPrefix(iOSRuntimePrefix) }
    guard !available.isEmpty else {
        throw ResolverError.noAvailableIOSRuntime
    }
    for runtime in available where numericDotVersionComponents(in: runtime.version) == nil {
        throw ResolverError.invalidRuntimeVersion(runtime.version)
    }
    guard let selected = available.sorted(by: { left, right in
        let ordering = compareSemanticVersions(
            numericDotVersionComponents(in: left.version)!,
            numericDotVersionComponents(in: right.version)!
        )
        if ordering == .orderedSame {
            return left.identifier < right.identifier
        }
        return ordering == .orderedDescending
    }).first else {
        throw ResolverError.noAvailableIOSRuntime
    }
    return selected
}

func iPhoneProRank(_ deviceType: DeviceType) -> [Int]? {
    let pattern = #"^iPhone\s+(.+)\s+Pro$"#
    guard !deviceType.name.contains("Pro Max"),
          let expression = try? NSRegularExpression(pattern: pattern),
          let match = expression.firstMatch(
              in: deviceType.name,
              range: NSRange(deviceType.name.startIndex..<deviceType.name.endIndex, in: deviceType.name)
          ),
          let range = Range(match.range(at: 1), in: deviceType.name) else {
        return nil
    }
    return numericDotVersionComponents(in: String(deviceType.name[range]))
}

func newestIPhonePro(from deviceTypes: [DeviceType]) throws -> DeviceType {
    let candidates = deviceTypes.compactMap { deviceType -> (DeviceType, [Int])? in
        guard let rank = iPhoneProRank(deviceType) else { return nil }
        return (deviceType, rank)
    }
    guard let selected = candidates.sorted(by: { left, right in
        let ordering = compareSemanticVersions(left.1, right.1)
        if ordering == .orderedSame {
            return left.0.identifier < right.0.identifier
        }
        return ordering == .orderedDescending
    }).first?.0 else {
        throw ResolverError.noIPhonePro(deviceTypes.map(\.name).sorted())
    }
    return selected
}

func firstCapture(in value: String, pattern: String) -> String? {
    guard let expression = try? NSRegularExpression(pattern: pattern),
          let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..<value.endIndex, in: value)),
          let range = Range(match.range(at: 1), in: value) else {
        return nil
    }
    return String(value[range])
}

func iPadAirRank(_ deviceType: DeviceType) -> (generation: [Int], screen: Int)? {
    guard deviceType.name.hasPrefix("iPad Air") else {
        return nil
    }
    let generation: [Int]
    if let chipSource = firstCapture(in: deviceType.name, pattern: #"\(M([0-9]+(?:\.[0-9]+)*)\)"#),
       var chipGeneration = numericDotVersionComponents(in: chipSource),
       let chipMajor = chipGeneration.first {
        let (modelGeneration, overflow) = chipMajor.addingReportingOverflow(4)
        guard !overflow else { return nil }
        chipGeneration[0] = modelGeneration
        generation = chipGeneration
    } else if let ordinalSource = firstCapture(in: deviceType.name, pattern: #"\(([0-9]+)(?:st|nd|rd|th) generation\)"#),
              let ordinalGeneration = numericDotVersionComponents(in: ordinalSource) {
        generation = ordinalGeneration
    } else {
        return nil
    }
    let screenSource = firstCapture(in: deviceType.name, pattern: #"([0-9]+)-inch"#)
    guard screenSource == nil || Int(screenSource!) != nil else {
        return nil
    }
    let screen = screenSource.flatMap(Int.init) ?? 0
    return (generation, screen)
}

func newestIPadAir(from deviceTypes: [DeviceType]) throws -> DeviceType {
    let candidates = deviceTypes.compactMap { deviceType -> (DeviceType, [Int], Int)? in
        guard let rank = iPadAirRank(deviceType) else { return nil }
        return (deviceType, rank.generation, rank.screen)
    }
    guard let selected = candidates.sorted(by: { left, right in
        let generationOrdering = compareSemanticVersions(left.1, right.1)
        if generationOrdering != .orderedSame {
            return generationOrdering == .orderedDescending
        }
        if left.2 != right.2 {
            return left.2 > right.2
        }
        return left.0.identifier < right.0.identifier
    }).first?.0 else {
        throw ResolverError.noIPadAir(deviceTypes.map(\.name).sorted())
    }
    return selected
}

func reference(for deviceType: DeviceType) -> DeviceTypeReference {
    DeviceTypeReference(identifier: deviceType.identifier, name: deviceType.name)
}

func resolve(_ arguments: Arguments) throws -> Matrix {
    let runtimes = try decode(RuntimeList.self, from: arguments.runtimesPath)
    let deviceTypes = try decode(DeviceTypeList.self, from: arguments.deviceTypesPath)
    let devices = try decode(DeviceList.self, from: arguments.devicesPath)
    let runtime = try newestRuntime(from: runtimes.runtimes)
    guard devices.devices[runtime.identifier] != nil else {
        throw ResolverError.missingRuntimeDevices(runtime.identifier)
    }
    let needsIPhone = arguments.caseIDs.contains { $0.hasPrefix("iphone-") }
    let needsIPad = arguments.caseIDs.contains { $0.hasPrefix("ipad-") }
    let iPhoneType = try needsIPhone ? reference(for: newestIPhonePro(from: deviceTypes.devicetypes)) : nil
    let iPadType = try needsIPad ? reference(for: newestIPadAir(from: deviceTypes.devicetypes)) : nil
    let allCases: [MatrixCase] = [
        iPhoneType.map { MatrixCase(id: "iphone-en", family: "iPhone", deviceType: $0, locale: "en_US", language: "en") },
        iPhoneType.map { MatrixCase(id: "iphone-ja", family: "iPhone", deviceType: $0, locale: "ja_JP", language: "ja") },
        iPadType.map { MatrixCase(id: "ipad-en", family: "iPad", deviceType: $0, locale: "en_US", language: "en") },
        iPadType.map { MatrixCase(id: "ipad-ja", family: "iPad", deviceType: $0, locale: "ja_JP", language: "ja") }
    ].compactMap { $0 }

    return Matrix(
        schemaVersion: 1,
        scope: arguments.scope == "full" ? nil : arguments.scope,
        batchId: arguments.batchID,
        resolvedAt: arguments.resolvedAt,
        runtime: RuntimeReference(identifier: runtime.identifier, version: runtime.version),
        cases: allCases.filter { arguments.caseIDs.contains($0.id) }
    )
}

do {
    let arguments = try parseArguments(Array(CommandLine.arguments.dropFirst()))
    let matrix = try resolve(arguments)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(matrix)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
} catch let error as ResolverError {
    FileHandle.standardError.write(Data("\(error.message)\n".utf8))
    exit(1)
} catch {
    FileHandle.standardError.write(Data("blocked:environment: unable to resolve Simulator matrix: \(error)\n".utf8))
    exit(1)
}
