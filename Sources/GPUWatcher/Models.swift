import Foundation

/// One process holding memory on one GPU (a multi-GPU job appears once per GPU).
struct GPUProc: Identifiable, Equatable {
    var pid: Int
    var gpuMemMiB: Int?
    var gpuUtil: Int?          // per-process GPU utilisation ("sm" in nvidia-smi pmon)
    var user: String = "?"
    var elapsed: Int?          // seconds since the process started
    var cpu: Double?
    var rssKB: Int?
    var args: String = ""      // full command line
    var cwd: String?           // only readable for your own processes

    var id: Int { pid }

    /// Command line with the interpreter and script paths shortened to basenames,
    /// e.g. `/home/a/envs/x/bin/python /home/a/proj/train.py --lr 1e-4` -> `python train.py --lr 1e-4`.
    var prettyCommand: String {
        var t = args.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard !t.isEmpty else { return "pid \(pid)" }
        t[0] = (t[0] as NSString).lastPathComponent
        if let i = t.indices.dropFirst().first(where: { !t[$0].hasPrefix("-") }), t[i].hasPrefix("/") {
            t[i] = (t[i] as NSString).lastPathComponent
        }
        return t.joined(separator: " ")
    }
}

struct GPUInfo: Identifiable, Equatable {
    var index: Int
    var uuid: String
    var name: String
    var util: Int?
    var memUsedMiB: Int
    var memTotalMiB: Int
    var temp: Int?
    var power: Double?
    var fan: Int?
    var procs: [GPUProc] = []

    var id: String { uuid }

    var shortName: String {
        name.replacingOccurrences(of: "NVIDIA ", with: "")
            .replacingOccurrences(of: "GeForce ", with: "")
    }

    var memFraction: Double {
        memTotalMiB > 0 ? Double(memUsedMiB) / Double(memTotalMiB) : 0
    }

    var isBusy: Bool {
        !procs.isEmpty || (util ?? 0) >= 10 || memFraction > 0.05
    }
}

struct HostSnapshot: Equatable {
    var hostname: String = ""
    var user: String = ""
    var gpus: [GPUInfo] = []
    var gpuError: String?      // nvidia-smi missing / failed
    var load1: Double?
    var ncpu: Int?
    var ramTotalMB: Int?
    var ramUsedMB: Int?
}

enum ProbeError: Error, Equatable {
    case auth(String)          // key auth not available; needs a logged-in master connection
    case unreachable(String)
    case failed(String)

    var message: String {
        switch self {
        case .auth(let m), .unreachable(let m), .failed(let m): return m
        }
    }
}

struct HostState: Equatable {
    var snapshot: HostSnapshot?
    var error: ProbeError?
    var updated: Date?
}

enum Fmt {
    static func elapsed(_ s: Int) -> String {
        if s >= 86400 { return "\(s / 86400)d \(s % 86400 / 3600)h" }
        if s >= 3600 { return "\(s / 3600)h \(s % 3600 / 60)m" }
        if s >= 60 { return "\(s / 60)m" }
        return "\(s)s"
    }

    static func mib(_ m: Int) -> String {
        m >= 1024 ? String(format: "%.1fG", Double(m) / 1024) : "\(m)M"
    }

    static func memPair(used: Int, total: Int) -> String {
        String(format: "%.1f/%.0fG", Double(used) / 1024, Double(total) / 1024)
    }
}
