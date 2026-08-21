import Darwin
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("blocked:environment: \(message)\n".utf8))
    exit(1)
}

guard CommandLine.arguments.count == 7,
      CommandLine.arguments[1] == "--directory",
      CommandLine.arguments[3] == "--source",
      CommandLine.arguments[5] == "--destination" else {
    fail("usage: simulator-matrix-io.swift --directory <path> --source <name> --destination <name>")
}

let directory = CommandLine.arguments[2]
let source = CommandLine.arguments[4]
let destination = CommandLine.arguments[6]
guard !source.contains("/") && !destination.contains("/") && !source.isEmpty && !destination.isEmpty else {
    fail("unsafe artifact filename")
}
let directoryFD = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
guard directoryFD >= 0 else { fail("artifact directory is unavailable or a symlink") }
defer { close(directoryFD) }

var sourceInfo = stat()
guard fstatat(directoryFD, source, &sourceInfo, AT_SYMLINK_NOFOLLOW) == 0,
      (sourceInfo.st_mode & S_IFMT) == S_IFREG else {
    fail("artifact source is unavailable or not a regular file")
}
var destinationInfo = stat()
if fstatat(directoryFD, destination, &destinationInfo, AT_SYMLINK_NOFOLLOW) == 0 {
    fail("matrix publication collision")
}
guard errno == ENOENT else { fail("unable to check matrix destination") }
guard linkat(directoryFD, source, directoryFD, destination, 0) == 0 else {
    fail("exclusive matrix publication failed")
}
