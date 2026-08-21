import Darwin
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("blocked:environment: \(message)\n".utf8))
    exit(1)
}

func safeName(_ value: String, batch: Bool = false) -> String {
    let pattern = batch ? #"^[A-Za-z0-9][A-Za-z0-9-]{0,63}$"# : #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#
    guard value.range(of: pattern, options: .regularExpression) != nil else { fail("unsafe artifact name") }
    return value
}

func openRoot(_ path: String) -> Int32 {
    var before = stat()
    guard lstat(path, &before) == 0 else { fail("repository root is unavailable") }
    let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard fd >= 0 else { fail("repository root is unavailable or a symlink") }
    var after = stat()
    guard fstat(fd, &after) == 0, before.st_dev == after.st_dev, before.st_ino == after.st_ino else { fail("repository root changed while opening") }
    return fd
}

func directory(_ parent: Int32, _ name: String, create: Bool) -> Int32 {
    if create && mkdirat(parent, name, 0o700) != 0 && errno != EEXIST { fail("unable to create artifact directory") }
    let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard fd >= 0 else { fail("artifact directory is unavailable or a symlink") }
    return fd
}

func batchDirectory(repo: String, batch: String, create: Bool) -> Int32 {
    let root = openRoot(repo); defer { close(root) }
    let artifacts = directory(root, ".artifacts", create: create); defer { close(artifacts) }
    let batches = directory(artifacts, "batches", create: create); defer { close(batches) }
    return directory(batches, safeName(batch, batch: true), create: create)
}

func readAll(_ fd: Int32) -> Data {
    var data = Data(), buffer = [UInt8](repeating: 0, count: 65536)
    while true {
        let count = read(fd, &buffer, buffer.count)
        if count == 0 { return data }
        guard count > 0 else { fail("unable to read artifact") }
        data.append(buffer, count: Int(count))
    }
}

func writeAll(_ fd: Int32, _ data: Data) {
    data.withUnsafeBytes { raw in
        var offset = 0
        while offset < raw.count {
            let count = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
            guard count > 0 else { fail("unable to write artifact") }
            offset += Int(count)
        }
    }
    guard fsync(fd) == 0 else { fail("unable to fsync artifact") }
}

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 6, args[0] == "--operation", args[2] == "--repo", args[4] == "--batch" else { fail("invalid arguments") }
let operation = args[1], repo = args[3], batch = args[5], rest = Array(args.dropFirst(6))

switch operation {
case "exists":
    guard rest.count == 2, rest[0] == "--name" else { fail("exists requires --name") }
    let dir = batchDirectory(repo: repo, batch: batch, create: true); defer { close(dir) }
    let fd = openat(dir, safeName(rest[1]), O_RDONLY | O_NOFOLLOW)
    if fd >= 0 {
        close(fd)
        print("present")
    } else if errno == ENOENT {
        print("missing")
    } else {
        fail("artifact is unavailable or a symlink")
    }
case "store":
    guard rest.count == 2, rest[0] == "--name" else { fail("store requires --name") }
    let dir = batchDirectory(repo: repo, batch: batch, create: true); defer { close(dir) }
    let fd = openat(dir, safeName(rest[1]), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { fail("exclusive artifact creation failed") }; defer { close(fd) }
    writeAll(fd, readAll(STDIN_FILENO))
case "read":
    guard rest.count == 2, rest[0] == "--name" else { fail("read requires --name") }
    let dir = batchDirectory(repo: repo, batch: batch, create: false); defer { close(dir) }
    let fd = openat(dir, safeName(rest[1]), O_RDONLY | O_NOFOLLOW)
    guard fd >= 0 else { fail("artifact is unavailable or a symlink") }; defer { close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { fail("artifact is not a regular file") }
    FileHandle.standardOutput.write(readAll(fd))
case "publish", "replace":
    guard rest.count == 4, rest[0] == "--source", rest[2] == "--name" else { fail("publish requires --source and --name") }
    let source = open(rest[1], O_RDONLY | O_NOFOLLOW)
    guard source >= 0 else { fail("source is unavailable or a symlink") }; defer { close(source) }
    var sourceInfo = stat()
    guard fstat(source, &sourceInfo) == 0, (sourceInfo.st_mode & S_IFMT) == S_IFREG else { fail("source is not a regular file") }
    let data = readAll(source)
    let dir = batchDirectory(repo: repo, batch: batch, create: true); defer { close(dir) }
    let name = safeName(rest[3])
    if operation == "publish" {
        let destination = openat(dir, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard destination >= 0 else { fail("exclusive artifact publication failed") }; defer { close(destination) }
        writeAll(destination, data)
    } else {
        let temporary = ".replace-\(UUID().uuidString)"
        let destination = openat(dir, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard destination >= 0 else { fail("exclusive artifact temporary creation failed") }
        writeAll(destination, data)
        close(destination)
        guard renameat(dir, temporary, dir, name) == 0 else { unlinkat(dir, temporary, 0); fail("atomic artifact replacement failed") }
    }
case "write-unique":
    guard rest.count == 4, rest[0] == "--source", rest[2] == "--prefix" else { fail("write-unique requires --source and --prefix") }
    let source = open(rest[1], O_RDONLY | O_NOFOLLOW)
    guard source >= 0 else { fail("source is unavailable or a symlink") }; defer { close(source) }
    let data = readAll(source)
    let dir = batchDirectory(repo: repo, batch: batch, create: true); defer { close(dir) }
    let name = "\(safeName(rest[3]))-\(UUID().uuidString).json"
    let destination = openat(dir, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    guard destination >= 0 else { fail("exclusive failure report creation failed") }; defer { close(destination) }
    writeAll(destination, data)
    print(name)
default:
    fail("unsupported artifact operation")
}
