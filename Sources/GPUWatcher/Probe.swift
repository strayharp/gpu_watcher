import AppKit
import Foundation

/// The read-only script run on each server (piped to `bash -s` over ssh).
/// Output is split into `@@SECTION` blocks that `ProbeParser` understands.
let probeScript = #"""
export LC_ALL=C
echo "@@HOST"
hostname
whoami
echo "@@GPU"
nvidia-smi --query-gpu=index,uuid,name,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw,fan.speed --format=csv,noheader,nounits 2>&1
echo "@@APPS"
apps=$(nvidia-smi --query-compute-apps=gpu_uuid,pid,used_memory --format=csv,noheader,nounits 2>/dev/null)
echo "$apps"
pids=$(echo "$apps" | awk -F', *' 'NF>=2{print $2}' | sort -un | paste -sd, -)
echo "@@PMON"
nvidia-smi pmon -c 1 -s um 2>/dev/null
echo "@@PS"
if [ -n "$pids" ]; then
  ps -ww -o pid=PID -o user=USER............................ -o etimes=ELAPSED -o pcpu=CPU -o rss=RSS -o args=ARGS -p "$pids" 2>/dev/null
fi
echo "@@CWD"
for p in $(echo "$pids" | tr ',' ' '); do
  printf '%s\t%s\n' "$p" "$(readlink "/proc/$p/cwd" 2>/dev/null)"
done
echo "@@SYS"
cat /proc/loadavg
nproc
free -m | awk '/^Mem:/{print $2, $3}'
echo "@@END"
"""#

enum ProbeParser {
    /// Returns nil when the output is incomplete (ssh failed before the script finished).
    static func parse(_ text: String) -> HostSnapshot? {
        var sections: [String: [String]] = [:]
        var current = ""
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            if line.hasPrefix("@@") {
                current = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                sections[current, default: []] = []
            } else if !current.isEmpty {
                sections[current, default: []].append(line)
            }
        }
        guard sections["END"] != nil, let hostLines = sections["HOST"] else { return nil }

        var snap = HostSnapshot()
        snap.hostname = hostLines.first?.trimmingCharacters(in: .whitespaces) ?? ""
        snap.user = hostLines.dropFirst().first?.trimmingCharacters(in: .whitespaces) ?? ""

        // GPUs
        var gpus: [GPUInfo] = []
        var junk: [String] = []
        for line in sections["GPU"] ?? [] {
            let f = csv(line)
            guard f.count >= 6, let idx = Int(f[0]), let total = num(f[5]) else {
                if !line.trimmingCharacters(in: .whitespaces).isEmpty { junk.append(line) }
                continue
            }
            gpus.append(GPUInfo(
                index: idx, uuid: f[1], name: f[2],
                util: num(f[3]).map(Int.init),
                memUsedMiB: Int(num(f[4]) ?? 0), memTotalMiB: Int(total),
                temp: f.count > 6 ? num(f[6]).map(Int.init) : nil,
                power: f.count > 7 ? num(f[7]) : nil,
                fan: f.count > 8 ? num(f[8]).map(Int.init) : nil))
        }
        if gpus.isEmpty {
            let msg = junk.last?.trimmingCharacters(in: .whitespaces) ?? "no GPUs reported"
            snap.gpuError = msg.contains("not found") ? "nvidia-smi not found on this host" : msg
        }

        // Per-process details from ps
        struct PS { var user: String; var elapsed: Int?; var cpu: Double?; var rss: Int?; var args: String }
        var ps: [Int: PS] = [:]
        for line in sections["PS"] ?? [] {
            let f = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
            guard f.count >= 5, let pid = Int(f[0]) else { continue }   // skips the header row
            ps[pid] = PS(user: String(f[1]), elapsed: Int(f[2]), cpu: Double(f[3]), rss: Int(f[4]),
                         args: f.count > 5 ? f[5].trimmingCharacters(in: .whitespaces) : "")
        }

        var cwd: [Int: String] = [:]
        for line in sections["CWD"] ?? [] {
            let f = line.split(separator: "\t", maxSplits: 1)
            if f.count == 2, let pid = Int(f[0]), !f[1].isEmpty { cwd[pid] = String(f[1]) }
        }

        // Per-process GPU utilisation from `nvidia-smi pmon`; columns vary by driver, so read the header.
        var sm: [String: Int] = [:]
        var gpuCol = 0, pidCol = 1, smCol = 3
        for line in sections["PMON"] ?? [] {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("#") {
                let h = t.dropFirst().split(separator: " ").map(String.init)
                if let g = h.firstIndex(of: "gpu"), let p = h.firstIndex(of: "pid"), let s = h.firstIndex(of: "sm") {
                    (gpuCol, pidCol, smCol) = (g, p, s)
                }
                continue
            }
            let f = t.split(separator: " ")
            guard f.count > max(gpuCol, pidCol, smCol), let pid = Int(f[pidCol]), let v = Int(f[smCol]) else { continue }
            sm["\(f[gpuCol])-\(pid)"] = v
        }

        // Attach processes to GPUs
        for line in sections["APPS"] ?? [] {
            let f = csv(line)
            guard f.count >= 2, let pid = Int(f[1]), let gi = gpus.firstIndex(where: { $0.uuid == f[0] }) else { continue }
            var p = GPUProc(pid: pid)
            p.gpuMemMiB = f.count > 2 ? num(f[2]).map(Int.init) : nil
            p.gpuUtil = sm["\(gpus[gi].index)-\(pid)"]
            if let info = ps[pid] {
                p.user = info.user; p.elapsed = info.elapsed; p.cpu = info.cpu; p.rssKB = info.rss; p.args = info.args
            }
            p.cwd = cwd[pid]
            if !gpus[gi].procs.contains(where: { $0.pid == pid }) { gpus[gi].procs.append(p) }
        }
        for i in gpus.indices {
            gpus[i].procs.sort { ($0.gpuMemMiB ?? 0) > ($1.gpuMemMiB ?? 0) }
        }
        snap.gpus = gpus.sorted { $0.index < $1.index }

        // System
        let sys = sections["SYS"] ?? []
        if sys.count > 0 { snap.load1 = sys[0].split(separator: " ").first.flatMap { Double($0) } }
        if sys.count > 1 { snap.ncpu = Int(sys[1].trimmingCharacters(in: .whitespaces)) }
        if sys.count > 2 {
            let f = sys[2].split(separator: " ")
            if f.count >= 2 { snap.ramTotalMB = Int(f[0]); snap.ramUsedMB = Int(f[1]) }
        }
        return snap
    }

    private static func csv(_ line: String) -> [String] {
        line.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// nvidia-smi prints "[N/A]" / "[Not Supported]" for unavailable fields.
    private static func num(_ s: String) -> Double? { Double(s) }
}

enum SSH {
    /// ssh aliases are passed to ssh and written into a login script, so keep them to a safe alphabet.
    static func isValidHost(_ h: String) -> Bool {
        h.range(of: #"^[A-Za-z0-9_][A-Za-z0-9._@\-]*$"#, options: .regularExpression) != nil
    }

    /// Directory for our own connection-sharing sockets (short path: unix sockets are limited to 104 bytes).
    static func controlDir() -> String {
        let dir = "/tmp/gpuwatcher-\(getuid())"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return dir
    }

    static let defaultConfigPath = NSHomeDirectory() + "/.ssh/config"
    static let configPathKey = "sshConfigPath"

    /// The user-chosen ssh config file (absolute path), or nil to use ssh's defaults.
    /// Read from UserDefaults on every use so the app, the login script and `--probe` always agree.
    static var customConfigPath: String? {
        guard let raw = UserDefaults.standard.string(forKey: configPathKey)?
            .trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        let path = (raw as NSString).expandingTildeInPath
        return path == defaultConfigPath ? nil : path
    }

    static var effectiveConfigPath: String { customConfigPath ?? defaultConfigPath }

    private static func shQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func configHosts() -> [String] {
        guard let text = try? String(contentsOfFile: effectiveConfigPath, encoding: .utf8) else { return [] }
        var out: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" })
            guard parts.count >= 2, parts[0].lowercased() == "host" else { continue }
            for h in parts.dropFirst().map(String.init) where isValidHost(h) && !out.contains(h) {
                out.append(h)
            }
        }
        return out
    }

    struct Output { var status: Int32; var out: String; var err: String }

    static func run(_ args: [String], stdin: String? = nil, extraEnv: [String: String] = [:],
                    timeout: TimeInterval) async -> Output {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let p = Process()
                var env = ProcessInfo.processInfo.environment
                // GPUWATCHER_SSH swaps in a stand-in ssh binary for testing.
                p.executableURL = URL(fileURLWithPath: env["GPUWATCHER_SSH"] ?? "/usr/bin/ssh")
                p.arguments = args
                // Apps launched from Finder get a minimal PATH; ProxyCommand helpers often live in Homebrew.
                env["PATH"] = (env["PATH"] ?? "/usr/bin:/bin") + ":/opt/homebrew/bin:/usr/local/bin"
                env.merge(extraEnv) { $1 }
                p.environment = env

                let inPipe = Pipe(), outPipe = Pipe()
                // stderr goes to a file, not a pipe: a backgrounded ssh master must never be able to hold our read open.
                let errPath = "\(controlDir())/err-\(UUID().uuidString)"
                FileManager.default.createFile(atPath: errPath, contents: nil, attributes: [.posixPermissions: 0o600])
                let errHandle = FileHandle(forWritingAtPath: errPath)
                p.standardInput = inPipe
                p.standardOutput = outPipe
                p.standardError = errHandle ?? FileHandle.nullDevice
                defer {
                    try? errHandle?.close()
                    try? FileManager.default.removeItem(atPath: errPath)
                }

                do { try p.run() } catch {
                    cont.resume(returning: Output(status: -1, out: "", err: error.localizedDescription))
                    return
                }
                if let stdin, let data = stdin.data(using: .utf8) {
                    try? inPipe.fileHandleForWriting.write(contentsOf: data)
                }
                try? inPipe.fileHandleForWriting.close()

                let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                killer.cancel()

                let err = (try? String(contentsOfFile: errPath, encoding: .utf8)) ?? ""
                cont.resume(returning: Output(status: p.terminationStatus,
                                              out: String(decoding: outData, as: UTF8.self), err: err))
            }
        }
    }

    /// Options every ssh call shares: which config file to read, and where our shared connections live.
    private static func shareOpts() -> [String] {
        (customConfigPath.map { ["-F", $0] } ?? []) + ["-o", "ControlPath=\(controlDir())/%C"]
    }

    /// True when a shared (already authenticated) connection to the host exists. Purely local, no network traffic.
    static func masterAlive(_ host: String) async -> Bool {
        let r = await run(shareOpts() + ["-O", "check", "--", host], timeout: 5)
        return r.status == 0
    }

    /// With `withSavedPassword`, ssh may ask for a password and gets the one saved in the keychain (via
    /// `Askpass`); the authenticated connection then stays in the background for later probes to reuse.
    static func probe(host: String, withSavedPassword: Bool = false) async -> Result<HostSnapshot, ProbeError> {
        guard isValidHost(host) else { return .failure(.failed("invalid host name")) }
        var opts = [
            "-o", "ConnectTimeout=8",
            "-o", "ControlMaster=auto",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=2",
        ]
        var env: [String: String] = [:]
        if withSavedPassword, let exe = Bundle.main.executablePath {
            // One prompt only: a wrong saved password must cost a single failed attempt, not three.
            opts += ["-o", "NumberOfPasswordPrompts=1", "-o", "ControlPersist=yes"]
            env = ["SSH_ASKPASS": exe, "SSH_ASKPASS_REQUIRE": "force", Askpass.hostEnv: host]
        } else {
            opts += ["-o", "BatchMode=yes", "-o", "ControlPersist=600"]   // never prompt
        }
        let args = shareOpts() + opts + ["-T", "--", host, "bash -s"]
        let r = await run(args, stdin: probeScript, extraEnv: env, timeout: 30)
        if let snap = ProbeParser.parse(r.out) { return .success(snap) }

        let lines = r.err.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("Warning: Permanently added") }
        let last = lines.last ?? (r.status == 15 || r.status == -1 ? "timed out" : "no output from host")
        let low = r.err.lowercased()
        if low.contains("permission denied") || low.contains("too many authentication failures") {
            return .failure(.auth(last))
        }
        if ["timed out", "could not resolve", "no route to host", "connection refused", "network is unreachable",
            "connection closed", "connection reset"].contains(where: low.contains) || lines.isEmpty {
            return .failure(.unreachable(last))
        }
        return .failure(.failed(last))
    }

    /// Opens Terminal with an interactive ssh that authenticates once (password / 2FA) and then stays in the
    /// background as a shared connection the app can reuse. The app itself never sees the password.
    static func openLogin(host: String) {
        guard isValidHost(host) else { return }
        let dir = controlDir()
        let path = "\(dir)/login-\(host).command"
        let config = customConfigPath.map { "-F \(shQuote($0)) " } ?? ""
        let script = """
        #!/bin/sh
        clear
        echo "GPU Watcher: log in to \(host)"
        echo "The connection stays open in the background so the menu bar app can reuse it."
        echo
        /usr/bin/ssh \(config)-o ControlPath='\(dir)/%C' -O exit -- '\(host)' 2>/dev/null
        if /usr/bin/ssh \(config)-o ControlMaster=yes -o ControlPath='\(dir)/%C' -o ControlPersist=yes \\
            -o ServerAliveInterval=30 -fN -- '\(host)'; then
          echo
          echo "Logged in. You can close this window."
        else
          echo
          echo "Login failed."
        fi
        """
        do {
            try script.write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        } catch {
            NSLog("GPUWatcher: could not write login script: \(error)")
        }
    }
}
