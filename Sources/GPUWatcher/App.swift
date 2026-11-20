import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--selfshot"), i + 1 < args.count { selfshot(dir: args[i + 1]) }
    }

    /// Developer aid: open the real popover, save PNGs of the app's own windows, then quit.
    private func selfshot(dir: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            let status = NSApp.windows.first { $0.className.contains("StatusBar") }
            func find(_ v: NSView?) -> NSControl? {
                guard let v else { return nil }
                if let c = v as? NSStatusBarButton { return c }
                for sub in v.subviews { if let c = find(sub) { return c } }
                return nil
            }
            let button = find(status?.contentView)
            button?.performClick(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                for (i, w) in NSApp.windows.enumerated() where w.isVisible && !w.className.contains("StatusBar") {
                    guard let v = w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { continue }
                    v.cacheDisplay(in: v.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: "\(dir)/win\(i).png"))
                    print("saved win\(i).png", w.className, w.frame)
                }
                exit(0)
            }
        }
    }
}

struct GPUWatcherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = Store(demo: CommandLine.arguments.contains("--demo"))

    var body: some Scene {
        MenuBarExtra {
            PopoverView(store: store)
        } label: {
            MenuLabel(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}

@main
enum Main {
    @MainActor
    static func main() {
        Askpass.runIfRequested()   // ssh is asking this binary for a saved password; answers and exits
        signal(SIGPIPE, SIG_IGN)   // an ssh that dies early must not take the app down when we write to its stdin
        let args = CommandLine.arguments
        if args.contains("--selftest-askpass") { selftestAskpass() }
        if let i = args.firstIndex(of: "--render"), i + 1 < args.count {
            // Developer aid: draw the popover with demo data to a PNG and exit.
            renderDemo(to: args[i + 1], dark: args.contains("--dark"))
            return
        }
        if let i = args.firstIndex(of: "--probe"), i + 1 < args.count {
            // Diagnostic: run one probe against a host and print what the app would see.
            let host = args[i + 1]
            Task {
                switch await SSH.probe(host: host) {
                case .success(let s):
                    print("\(s.user)@\(s.hostname): \(s.gpus.count) GPU(s)" + (s.gpuError.map { " (\($0))" } ?? ""))
                    for g in s.gpus {
                        print("  [\(g.index)] \(g.shortName)  util \(g.util.map(String.init) ?? "n/a")%  mem \(Fmt.memPair(used: g.memUsedMiB, total: g.memTotalMiB))")
                        for p in g.procs {
                            print("      \(p.user)  pid \(p.pid)  \(p.gpuMemMiB.map(Fmt.mib) ?? "?")  \(p.elapsed.map(Fmt.elapsed) ?? "?")  \(p.prettyCommand)")
                        }
                    }
                    exit(0)
                case .failure(let e):
                    print("error: \(e)")
                    exit(1)
                }
            }
            dispatchMain()
        }
        GPUWatcherApp.main()
    }

    /// Developer aid: round-trips a throwaway secret through the keychain and the askpass mode, the way ssh
    /// would call it, then removes it.
    private static func selftestAskpass() -> Never {
        let host = "gpuwatcher-selftest"
        let secret = "dummy-\(UUID().uuidString)"
        func ask(_ prompt: String, kind: String? = nil) -> (status: Int32, out: String) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: Bundle.main.executablePath!)
            p.arguments = [prompt]
            var env = ProcessInfo.processInfo.environment
            env[Askpass.hostEnv] = host
            env["SSH_ASKPASS_PROMPT"] = kind
            p.environment = env
            let pipe = Pipe()
            p.standardOutput = pipe
            try? p.run()
            let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            return (p.terminationStatus, out.trimmingCharacters(in: .newlines))
        }
        var ok = true
        func check(_ name: String, _ pass: Bool) { print("\(pass ? "ok  " : "FAIL") \(name)"); ok = ok && pass }

        check("save to keychain", Keychain.set(secret, host: host))
        check("exists without reading", Keychain.has(host: host))
        let pw = ask("alice@\(host)'s password: ")
        check("password prompt answered", pw.status == 0 && pw.out == secret)
        let ki = ask("(alice@\(host)) Password: ")
        check("keyboard-interactive password prompt answered", ki.status == 0 && ki.out == secret)
        let hk = ask("Are you sure you want to continue connecting (yes/no/[fingerprint])? ", kind: "confirm")
        check("host-key confirmation refused", hk.status != 0 && hk.out.isEmpty)
        let pp = ask("Enter passphrase for key '/Users/alice/.ssh/id_ed25519': ")
        check("key passphrase refused", pp.status != 0 && pp.out.isEmpty)
        let otp = ask("Verification code: ")
        check("2FA code refused", otp.status != 0 && otp.out.isEmpty)
        check("delete from keychain", Keychain.delete(host: host) && !Keychain.has(host: host))
        let gone = ask("alice@\(host)'s password: ")
        check("nothing answered after delete", gone.status != 0 && gone.out.isEmpty)
        exit(ok ? 0 : 1)
    }

    @MainActor
    private static func renderDemo(to path: String, dark: Bool) {
        let app = NSApplication.shared
        app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let view = PopoverView(store: Store(demo: true), scrolls: false)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, dark ? .dark : .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("render failed\n".utf8))
            exit(1)
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }
}
