#!/usr/bin/env swift

import Foundation

struct LinkFailure {
    let source: String
    let destination: String
}

func markdownFiles(in root: String) -> [String] {
    let fileManager = FileManager.default
    var files = ["README.md", "AGENTS.md"].filter { fileManager.fileExists(atPath: $0) }

    for directory in ["specs", "docs"] where fileManager.fileExists(atPath: directory) {
        guard let enumerator = fileManager.enumerator(atPath: directory) else { continue }
        while let entry = enumerator.nextObject() as? String {
            guard !entry.isEmpty else { continue }
            if entry.hasSuffix(".md") {
                files.append((directory as NSString).appendingPathComponent(entry))
            }
        }
    }

    return files.sorted()
}

func normalizedDestination(_ rawDestination: String) -> String? {
    var destination = rawDestination.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !destination.isEmpty else { return nil }

    if destination.hasPrefix("<"), destination.hasSuffix(">") {
        destination.removeFirst()
        destination.removeLast()
    }

    let lowercase = destination.lowercased()
    if destination.hasPrefix("#") || lowercase.hasPrefix("http://") ||
        lowercase.hasPrefix("https://") || lowercase.hasPrefix("mailto:") {
        return nil
    }

    destination = String(destination.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0])
    return destination.removingPercentEncoding ?? destination
}

func failures(in files: [String]) throws -> [LinkFailure] {
    let pattern = #"\[[^\]]*\]\(([^)]+)\)"#
    let regex = try NSRegularExpression(pattern: pattern)
    let fileManager = FileManager.default
    var failures: [LinkFailure] = []

    for file in files {
        let contents = try String(contentsOfFile: file, encoding: .utf8)
        let range = NSRange(contents.startIndex..<contents.endIndex, in: contents)

        for match in regex.matches(in: contents, range: range) {
            guard let captureRange = Range(match.range(at: 1), in: contents),
                  let destination = normalizedDestination(String(contents[captureRange])),
                  !destination.isEmpty else { continue }

            let sourceDirectory = (file as NSString).deletingLastPathComponent
            let resolved = (sourceDirectory as NSString).appendingPathComponent(destination)
            if !fileManager.fileExists(atPath: resolved) {
                failures.append(LinkFailure(source: file, destination: destination))
            }
        }
    }

    return failures
}

let arguments = Array(CommandLine.arguments.dropFirst())
let files = arguments.isEmpty ? markdownFiles(in: FileManager.default.currentDirectoryPath) : arguments

do {
    let missing = try failures(in: files)
    for failure in missing {
        FileHandle.standardError.write(Data("\(failure.source): missing local Markdown target: \(failure.destination)\n".utf8))
    }
    exit(missing.isEmpty ? EXIT_SUCCESS : EXIT_FAILURE)
} catch {
    FileHandle.standardError.write(Data("Markdown link check failed: \(error)\n".utf8))
    exit(EXIT_FAILURE)
}
