import AppKit
import Darwin

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func processInfo(_ pid: pid_t) -> proc_bsdinfo? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout.size(ofValue: info))
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_uid == getuid() else { return nil }
    return info
}

func sameProcess(_ lhs: proc_bsdinfo, _ rhs: proc_bsdinfo) -> Bool {
    lhs.pbi_pid == rhs.pbi_pid && lhs.pbi_start_tvsec == rhs.pbi_start_tvsec && lhs.pbi_start_tvusec == rhs.pbi_start_tvusec
}

func canonical(_ path: String?) -> String? {
    guard let path, let resolved = realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
}

func executable(_ pid: pid_t) -> String? {
    var path = [CChar](repeating: 0, count: 4096)
    guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
    return canonical(String(cString: path))
}

func arguments(_ pid: pid_t) -> [String] {
    var key = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&key, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
    var bytes = [UInt8](repeating: 0, count: size)
    guard sysctl(&key, 3, &bytes, &size, nil, 0) == 0 else { return [] }
    let count = bytes.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
    let strings = bytes[MemoryLayout<Int32>.size..<size].split(separator: 0, omittingEmptySubsequences: false)
    return strings.dropFirst().drop(while: \.isEmpty).prefix(count).map { String(decoding: $0, as: UTF8.self) }
}

func workingDirectory(_ pid: pid_t) -> String? {
    var paths = proc_vnodepathinfo()
    let size = Int32(MemoryLayout.size(ofValue: paths))
    guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &paths, size) == size else { return nil }
    return withUnsafeBytes(of: paths.pvi_cdir.vip_path) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
}

func run() throws {
    let args = CommandLine.arguments
    guard (args.count == 4 && args[1] == "check") || (args.count == 5 && args[1] == "hold"),
          let appPID = pid_t(args[3]), appPID > 1 else { throw Failure("Invalid fixture watchdog arguments.") }
    let root = URL(fileURLWithPath: args[2], isDirectory: true)
    let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
    let bundle = root.appendingPathComponent("Pi Workspace.app", isDirectory: true)
    let app = bundle.appendingPathComponent("Contents/MacOS/PiWorkspace").path
    let workspace = root.appendingPathComponent("workspace", isDirectory: true).path
    let project = root.appendingPathComponent("project", isDirectory: true).path
    let node = bundle.appendingPathComponent("Contents/Helpers/node").path
    let worker = bundle.appendingPathComponent("Contents/Resources/Sidecar/worker.mjs").path
    let appArgs = arguments(appPID)
    guard root.path == args[2], canonical(root.path) == root.path,
          root.deletingLastPathComponent().path == "/private/tmp", root.lastPathComponent.hasPrefix("pi-stop-retry-"),
          attributes[.ownerAccountID] as? UInt32 == getuid(), attributes[.posixPermissions] as? UInt16 == 0o700,
          let running = NSRunningApplication(processIdentifier: appPID),
          running.bundleIdentifier == "dev.piworkspace.app", canonical(running.bundleURL?.path) == bundle.path,
          let appInfo = processInfo(appPID), executable(appPID) == app,
          canonical(appArgs.first) == app, appArgs.dropFirst().starts(with: ["--workspace", workspace]),
          appArgs.filter({ $0 == "--workspace" }).count == 1 else {
        throw Failure("The app is not the exact private Launch Services instance.")
    }
    guard !running.isActive, running.isHidden else { throw Failure("The fixture must stay hidden and in the background.") }
    if args[1] == "check" { return }

    guard let pid = pid_t(args[4]), pid > 1 else { throw Failure("Invalid bundled Pi worker PID.") }
    let workerArgs = arguments(pid)
    guard let workerInfo = processInfo(pid), workerInfo.pbi_ppid == UInt32(appPID), executable(pid) == node,
          workerArgs.count == 2, canonical(workerArgs.first) == node, canonical(workerArgs.last) == worker,
          canonical(workingDirectory(pid)) == project,
          let currentApp = processInfo(appPID), sameProcess(appInfo, currentApp),
          let currentWorker = processInfo(pid), sameProcess(workerInfo, currentWorker),
          currentWorker.pbi_status != UInt32(SSTOP) else { throw Failure("The selected process is not the private app's bundled Pi worker.") }

    func resume() -> Bool {
        guard let current = processInfo(pid), sameProcess(workerInfo, current), executable(pid) == node else { return false }
        return kill(pid, SIGCONT) == 0
    }
    signal(SIGPIPE, SIG_IGN)
    guard kill(pid, SIGSTOP) == 0 else { throw Failure("Could not suspend the verified Pi worker.") }
    var resumed = false
    defer { if !resumed { _ = resume() } }
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(18)
    while processInfo(pid)?.pbi_status != UInt32(SSTOP) {
        guard clock.now < deadline else { throw Failure("The verified Pi worker did not enter the stopped state.") }
        usleep(10_000)
    }
    print("held \(pid)")
    fflush(stdout)

    // The detached watchdog owns the suspension. EOF, a deadline, or any error releases it.
    var pipe = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
    let remaining = clock.now.duration(to: deadline).components
    let milliseconds = remaining.seconds * 1_000 + remaining.attoseconds / 1_000_000_000_000_000
    let ready = poll(&pipe, 1, Int32(max(0, milliseconds)))
    var command: UInt8 = 0
    let requestedResume = ready == 1 && read(STDIN_FILENO, &command, 1) == 1 && command == 82
    let wasStopped = processInfo(pid)?.pbi_status == UInt32(SSTOP)
    resumed = resume()
    guard resumed, wasStopped else { throw Failure("The bundled Pi worker did not remain stopped until watchdog release.") }
    print(requestedResume ? "resumed on request" : "resumed after timeout or controller disconnect")
    guard requestedResume else { throw Failure("The controller did not request resume before the watchdog deadline.") }
}

do { try run() }
catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
