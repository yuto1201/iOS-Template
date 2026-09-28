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

struct DedicatedDevice: Codable {
    let family: String
    let name: String
    let deviceTypeIdentifier: String
    let runtimeIdentifier: String
}

struct DedicatedConfig: Codable {
    let schemaVersion: Int
    let devices: [DedicatedDevice]
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
    let dedicatedConfigPath: String
    let deviceTypesPath: String
    let batchID: String
    let resolvedAt: String
    let scope: String
    let caseIDs: [String]
}

enum ResolverError: Error {
    case usage
    case unreadableInput(String)
    case invalidDedicatedConfig(String)
    case unavailableRuntime(String)
    case invalidRuntimeVersion(String)
    case unavailableDeviceType(String)

    var message: String {
        switch self {
        case .usage:
            return "usage: resolve-simulator-matrix.swift --runtimes <path> --device-types <path> --dedicated-config <path> --batch-id <id> [--resolved-at <ISO-8601 timestamp>] [--scope iphone-ja|targeted|full] [--case-ids id,id]"
        case .unreadableInput(let path):
            return "blocked:environment: unable to decode JSON input: \(path)"
        case .invalidDedicatedConfig(let reason):
            return "blocked:environment: invalid dedicated Simulator declaration: \(reason)"
        case .unavailableRuntime(let identifier):
            return "blocked:environment: declared Runtime is not installed and available: \(identifier)"
        case .invalidRuntimeVersion(let version):
            return "blocked:environment: invalid declared Runtime version: \(version)"
        case .unavailableDeviceType(let identifier):
            return "blocked:environment: declared Device Type is not installed: \(identifier)"
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
        guard ["--runtimes", "--device-types", "--dedicated-config", "--batch-id", "--resolved-at", "--scope", "--case-ids"].contains(flag),
              values[flag] == nil,
              !value.isEmpty else {
            throw ResolverError.usage
        }
        values[flag] = value
        index += 2
    }

    guard let runtimesPath = values["--runtimes"],
          let deviceTypesPath = values["--device-types"],
          let dedicatedConfigPath = values["--dedicated-config"],
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
        dedicatedConfigPath: dedicatedConfigPath,
        deviceTypesPath: deviceTypesPath,
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

// Reads the tracked declaration of the two dedicated Simulators (D-063).
func dedicatedDevices(from path: String) throws -> (iPhone: DedicatedDevice, iPad: DedicatedDevice) {
    let config = try decode(DedicatedConfig.self, from: path)
    guard config.schemaVersion == 1 else { throw ResolverError.invalidDedicatedConfig("schemaVersion must be 1") }
    guard config.devices.map(\.family) == ["iphone", "ipad"] else {
        throw ResolverError.invalidDedicatedConfig("exactly one iphone and one ipad device must be declared in that order")
    }
    let identifierPattern = #"^com\.apple\.CoreSimulator\.(SimRuntime|SimDeviceType)\.[A-Za-z0-9_.-]+$"#
    for device in config.devices {
        guard !device.name.isEmpty, !device.name.hasPrefix("iOS-Template-"),
              device.deviceTypeIdentifier.range(of: identifierPattern, options: .regularExpression) != nil,
              device.runtimeIdentifier.range(of: identifierPattern, options: .regularExpression) != nil else {
            throw ResolverError.invalidDedicatedConfig("device \(device.family) has an invalid name or identifier")
        }
    }
    guard config.devices[0].name != config.devices[1].name else {
        throw ResolverError.invalidDedicatedConfig("device names must be unique")
    }
    guard config.devices[0].runtimeIdentifier == config.devices[1].runtimeIdentifier else {
        throw ResolverError.invalidDedicatedConfig("both devices must use the same Runtime")
    }
    return (config.devices[0], config.devices[1])
}

func declaredRuntime(_ identifier: String, from runtimes: [Runtime]) throws -> Runtime {
    guard let runtime = runtimes.first(where: { $0.identifier == identifier && $0.isAvailable }) else {
        throw ResolverError.unavailableRuntime(identifier)
    }
    guard numericDotVersionComponents(in: runtime.version) != nil else {
        throw ResolverError.invalidRuntimeVersion(runtime.version)
    }
    return runtime
}

func declaredDeviceType(_ identifier: String, from deviceTypes: [DeviceType]) throws -> DeviceType {
    guard let deviceType = deviceTypes.first(where: { $0.identifier == identifier }) else {
        throw ResolverError.unavailableDeviceType(identifier)
    }
    return deviceType
}

func reference(for deviceType: DeviceType) -> DeviceTypeReference {
    DeviceTypeReference(identifier: deviceType.identifier, name: deviceType.name)
}

func resolve(_ arguments: Arguments) throws -> Matrix {
    let runtimes = try decode(RuntimeList.self, from: arguments.runtimesPath)
    let deviceTypes = try decode(DeviceTypeList.self, from: arguments.deviceTypesPath)
    let dedicated = try dedicatedDevices(from: arguments.dedicatedConfigPath)
    let runtime = try declaredRuntime(dedicated.iPhone.runtimeIdentifier, from: runtimes.runtimes)
    let needsIPhone = arguments.caseIDs.contains { $0.hasPrefix("iphone-") }
    let needsIPad = arguments.caseIDs.contains { $0.hasPrefix("ipad-") }
    let iPhoneType = try needsIPhone ? reference(for: declaredDeviceType(dedicated.iPhone.deviceTypeIdentifier, from: deviceTypes.devicetypes)) : nil
    let iPadType = try needsIPad ? reference(for: declaredDeviceType(dedicated.iPad.deviceTypeIdentifier, from: deviceTypes.devicetypes)) : nil
    let allCases: [MatrixCase] = [
        iPhoneType.map { MatrixCase(id: "iphone-en", family: "iPhone", deviceType: $0, locale: "en_US", language: "en") },
        iPhoneType.map { MatrixCase(id: "iphone-ja", family: "iPhone", deviceType: $0, locale: "ja_JP", language: "ja") },
        iPadType.map { MatrixCase(id: "ipad-en", family: "iPad", deviceType: $0, locale: "en_US", language: "en") },
        iPadType.map { MatrixCase(id: "ipad-ja", family: "iPad", deviceType: $0, locale: "ja_JP", language: "ja") }
    ].compactMap { $0 }

    return Matrix(
        schemaVersion: 2,
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
