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
    let cwd = open(".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard cwd >= 0 else { fail("working directory is unavailable") }
    var cwdInfo = stat(), pathInfo = stat()
    guard fstat(cwd, &cwdInfo) == 0, lstat(path, &pathInfo) == 0,
          cwdInfo.st_dev == pathInfo.st_dev, cwdInfo.st_ino == pathInfo.st_ino else {
        close(cwd); fail("helper must run from the verified repository root")
    }
    return cwd
}

func directory(_ parent: Int32, _ name: String, create: Bool) -> Int32 {
    if create && mkdirat(parent, name, 0o700) != 0 && errno != EEXIST { fail("unable to create artifact directory") }
    let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard fd >= 0 else { fail("artifact directory is unavailable or a symlink") }
    return fd
}

// A linked checkout may use only its primary's physical artifact store. Keep
// the directory chain and Git back-references open through the operation;
// never traverse the artifact symlink to select a write destination.
final class MatrixDirectoryLayout {
    let repository: String
    let caller: Int32
    var handles: [Int32] = []
    var directories: [(Int32, String, Int32)] = []
    var metadata: [(Int32, String, Int32, Data)] = []
    var artifactLink: stat?

    init(repo: String) {
        repository = repo
        caller = openRoot(repo)
        handles.append(caller)
    }

    deinit { handles.reversed().forEach { close($0) } }

    func sameNode(_ first: stat, _ second: stat) -> Bool {
        first.st_dev == second.st_dev && first.st_ino == second.st_ino &&
            (first.st_mode & S_IFMT) == (second.st_mode & S_IFMT)
    }

    func addDirectory(_ parent: Int32, _ name: String, create: Bool = false) -> Int32 {
        let fd = directory(parent, name, create: create)
        handles.append(fd)
        directories.append((parent, name, fd))
        return fd
    }

    func regularBytes(_ parent: Int32, _ name: String) -> Data {
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { fail("linked checkout Git metadata is unavailable") }
        handles.append(fd)
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_nlink == 1 else { fail("linked checkout Git metadata is not a regular single-link file") }
        let bytes = readAll(fd)
        metadata.append((parent, name, fd, bytes))
        return bytes
    }

    func linkTarget() -> String {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = readlinkat(caller, ".artifacts", &buffer, buffer.count)
        guard count > 0, count < buffer.count,
              let target = String(bytes: buffer.prefix(Int(count)), encoding: .utf8) else {
            fail("shared artifact link is unavailable")
        }
        return target
    }

    func artifacts(create: Bool) -> Int32 {
        var entry = stat()
        let found = fstatat(caller, ".artifacts", &entry, AT_SYMLINK_NOFOLLOW)
        guard found == 0 || errno == ENOENT else { fail("artifact directory cannot be inspected") }
        guard found == 0 && (entry.st_mode & S_IFMT) == S_IFLNK else {
            // Physical private stores remain valid in clean detached test worktrees.
            return addDirectory(caller, ".artifacts", create: create)
        }

        guard linkTarget() == "../../.artifacts" else { fail("shared artifact link is not canonical") }
        artifactLink = entry
        let components = repository.split(separator: "/", omittingEmptySubsequences: false)
        guard repository.hasPrefix("/"), !repository.contains("\0"), !repository.contains("\n"),
              components.count >= 4,
              components.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              components.dropLast().last == ".worktrees" else {
            fail("shared artifacts require an exact primary .worktrees child")
        }
        let primaryComponents = components.dropFirst().dropLast(2)
        let primaryPath = "/" + primaryComponents.joined(separator: "/")

        let filesystemRoot = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard filesystemRoot >= 0 else { fail("filesystem root is unavailable") }
        handles.append(filesystemRoot)
        var primary = filesystemRoot
        for component in primaryComponents {
            primary = addDirectory(primary, String(component))
        }
        let worktrees = addDirectory(primary, ".worktrees")
        let reopenedCaller = addDirectory(worktrees, String(components.last!))
        var current = stat(), reopened = stat()
        guard fstat(caller, &current) == 0, fstat(reopenedCaller, &reopened) == 0,
              sameNode(current, reopened) else { fail("linked checkout directory identity changed") }

        let git = addDirectory(primary, ".git")
        let gitWorktrees = addDirectory(git, "worktrees")
        let gitFile = regularBytes(caller, ".git")
        let prefix = "gitdir: \(primaryPath)/.git/worktrees/"
        guard let text = String(data: gitFile, encoding: .utf8), text.hasPrefix(prefix),
              text.hasSuffix("\n") else { fail("linked checkout Git path is not canonical") }
        let name = String(text.dropFirst(prefix.count).dropLast())
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"),
              !name.contains("\0"), !name.contains("\n") else { fail("unsafe worktree Git metadata path") }
        let gitWorktree = addDirectory(gitWorktrees, name)
        guard regularBytes(gitWorktree, "commondir") == Data("../..\n".utf8),
              regularBytes(gitWorktree, "gitdir") == Data("\(repository)/.git\n".utf8) else {
            fail("linked checkout Git back-references do not match")
        }
        verify()
        return addDirectory(primary, ".artifacts")
    }

    func verify() {
        var expected = stat(), current = stat()
        guard fstat(caller, &expected) == 0, lstat(repository, &current) == 0,
              sameNode(expected, current) else { fail("repository directory changed during artifact IO") }
        for (parent, name, fd) in directories {
            guard fstat(fd, &expected) == 0,
                  fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
                  sameNode(expected, current) else { fail("artifact directory chain changed during IO") }
        }
        if let original = artifactLink {
            guard fstatat(caller, ".artifacts", &current, AT_SYMLINK_NOFOLLOW) == 0,
                  sameNode(original, current), linkTarget() == "../../.artifacts" else {
                fail("shared artifact link changed during IO")
            }
        }
        for (parent, name, fd, bytes) in metadata {
            guard fstat(fd, &expected) == 0, expected.st_nlink == 1,
                  fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
                  sameNode(expected, current), lseek(fd, 0, SEEK_SET) == 0,
                  readAll(fd) == bytes else { fail("linked checkout Git metadata changed during IO") }
        }
    }
}

var activeLayout: MatrixDirectoryLayout?
defer { activeLayout?.verify() }

func batchDirectory(repo: String, batch: String, create: Bool) -> Int32 {
    let layout = MatrixDirectoryLayout(repo: repo)
    activeLayout = layout
    let artifacts = layout.artifacts(create: create)
    #if MATRIX_IO_TESTING
    if ProcessInfo.processInfo.environment["MATRIX_IO_TEST_LAYOUT_BARRIER"] == "stop-before-batch" {
        raise(SIGSTOP)
    }
    #endif
    layout.verify()
    let batches = layout.addDirectory(artifacts, "batches", create: create)
    let batchFD = layout.addDirectory(batches, safeName(batch, batch: true), create: create)
    layout.verify()
    let result = dup(batchFD)
    guard result >= 0 else { fail("unable to retain batch directory") }
    return result
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
    activeLayout?.verify()
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

func removePublicationTemporary(_ dir: Int32, _ name: String) {
    guard unlinkat(dir, name, 0) == 0 else { fail("unable to remove publication temporary") }
    guard fsync(dir) == 0 else { fail("unable to fsync artifact directory after removing publication temporary") }
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
        let temporary = ".publish-\(UUID().uuidString)"
        let destination = openat(dir, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard destination >= 0 else { fail("exclusive artifact publication temporary creation failed") }
        writeAll(destination, data)
        guard close(destination) == 0 else {
            removePublicationTemporary(dir, temporary)
            fail("unable to close publication temporary")
        }
        #if MATRIX_IO_TESTING
        if ProcessInfo.processInfo.environment["MATRIX_IO_TEST_PRELINK_FAILURE"] == "1" {
            removePublicationTemporary(dir, temporary)
            fail("injected pre-link publication failure")
        }
        #endif
        activeLayout?.verify()
        guard linkat(dir, temporary, dir, name, 0) == 0 else {
            removePublicationTemporary(dir, temporary)
            fail("exclusive artifact publication failed")
        }
        guard fsync(dir) == 0 else {
            removePublicationTemporary(dir, temporary)
            fail("unable to fsync artifact directory")
        }
        removePublicationTemporary(dir, temporary)
    } else {
        let temporary = ".replace-\(UUID().uuidString)"
        let destination = openat(dir, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard destination >= 0 else { fail("exclusive artifact temporary creation failed") }
        writeAll(destination, data)
        close(destination)
        activeLayout?.verify()
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
