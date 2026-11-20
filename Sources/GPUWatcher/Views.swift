import SwiftUI

struct MenuLabel: View {
    let store: Store
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "cpu")
            if !store.menuTitle.isEmpty { Text(store.menuTitle).monospacedDigit() }
        }
    }
}

struct PopoverView: View {
    let store: Store
    var scrolls = true
    @State private var showSettings: Bool
    @State private var contentHeight: CGFloat = 240

    init(store: Store, scrolls: Bool = true) {
        self.store = store
        self.scrolls = scrolls
        // First run starts on the server picker (`--settings` forces it, for screenshots).
        _showSettings = State(initialValue: store.hosts.isEmpty || CommandLine.arguments.contains("--settings"))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if showSettings {
                SettingsView(store: store) { showSettings = false }.padding(14)
            } else if scrolls {
                ScrollView {
                    hostList.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                }
                .frame(height: min(max(contentHeight, 60), 640))
            } else {
                hostList
            }
        }
        .frame(width: 520)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("GPU Watcher").font(.system(size: 13, weight: .semibold))
            let g = store.allGPUs
            if !g.isEmpty {
                Text("\(g.filter(\.isBusy).count) of \(g.count) GPUs busy")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            IconButton(symbol: store.onlyMine ? "person.fill" : "person.2",
                       help: store.onlyMine ? "Showing only my processes" : "Showing everyone's processes",
                       active: store.onlyMine) { store.onlyMine.toggle() }
            IconButton(symbol: "arrow.clockwise", help: "Refresh now") { store.refreshAll() }
            IconButton(symbol: "gearshape", help: "Servers & settings", active: showSettings) { showSettings.toggle() }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
    }

    private var hostList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(store.hosts.enumerated()), id: \.element) { i, host in
                if i > 0 { Divider().padding(.horizontal, 14) }
                HostSection(host: host, state: store.states[host] ?? HostState(), store: store)
                    .padding(.horizontal, 14).padding(.vertical, 10)
            }
        }
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(active ? Color.accentColor : Color.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct PillButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 9).padding(.vertical, 3)
                .background(Color.accentColor.opacity(0.18), in: Capsule())
                .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)
    }
}

struct HostSection: View {
    let host: String
    let state: HostState
    let store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 7, height: 7)
                Text(host).font(.system(size: 13, weight: .semibold))
                Spacer()
                if let s = state.snapshot {
                    Text(sysLine(s)).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                } else if state.error == nil {
                    Text("connecting…").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            if let e = state.error { errorRow(e) }
            if let s = state.snapshot {
                Group {
                    if let ge = s.gpuError {
                        Text(ge).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    ForEach(s.gpus) { gpu in
                        GPURow(gpu: gpu, me: s.user, onlyMine: store.onlyMine)
                    }
                }
                .opacity(state.error == nil ? 1 : 0.45)   // stale data while the host is failing
            }
        }
    }

    private var statusColor: Color {
        if state.error != nil { return .orange }
        return state.snapshot == nil ? .gray : .green
    }

    private func sysLine(_ s: HostSnapshot) -> String {
        var parts: [String] = []
        if let l = s.load1, let n = s.ncpu { parts.append(String(format: "load %.1f/%d", l, n)) }
        if let u = s.ramUsedMB, let t = s.ramTotalMB {
            parts.append(String(format: "RAM %.0f/%.0fG", Double(u) / 1024, Double(t) / 1024))
        }
        return parts.joined(separator: "  ·  ")
    }

    @ViewBuilder
    private func errorRow(_ e: ProbeError) -> some View {
        switch e {
        case .auth:
            AuthRow(host: host, store: store)
        case .unreachable(let m), .failed(let m):
            HStack(spacing: 8) {
                Text(m).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                PillButton(title: "Retry") { store.refresh(host) }
            }
        }
    }
}

/// Shown for a host that accepts no SSH key: enter the password once (kept in the keychain and reused to
/// reconnect), or log in through Terminal without saving anything.
struct AuthRow: View {
    let host: String
    let store: Store
    @State private var password = ""

    var body: some View {
        let rejected = store.rejectedPasswords.contains(host)
        VStack(alignment: .leading, spacing: 5) {
            if store.savedPasswords.contains(host) && !rejected {
                Text("Logging in with the saved password…")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                Text(rejected ? "The saved password was not accepted. Enter it again:"
                              : "Needs a login: no SSH key is accepted for this host.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    SecureField("Password", text: $password)
                        .textFieldStyle(.roundedBorder).font(.system(size: 11))
                        .onSubmit(submit)
                    PillButton(title: "Save & log in", action: submit)
                        .disabled(password.isEmpty).opacity(password.isEmpty ? 0.5 : 1)
                    PillButton(title: "Terminal…") { SSH.openLogin(host: host) }
                }
                Text("Kept in the macOS Keychain to reconnect automatically. Terminal… logs in without saving.")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
    }

    private func submit() {
        guard !password.isEmpty else { return }
        store.savePassword(password, for: host)
        password = ""
    }
}

struct GPURow: View {
    let gpu: GPUInfo
    let me: String
    let onlyMine: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text("\(gpu.index)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .frame(width: 14, alignment: .trailing)
                Text(gpu.shortName).font(.system(size: 11)).lineLimit(1)
                    .frame(width: 92, alignment: .leading)
                Meter(fraction: Double(gpu.util ?? 0) / 100, tint: .green,
                      label: gpu.util.map { "\($0)%" } ?? "n/a", labelWidth: 32)
                Meter(fraction: gpu.memFraction, tint: .blue,
                      label: Fmt.memPair(used: gpu.memUsedMiB, total: gpu.memTotalMiB), labelWidth: 62)
                Text(gpu.temp.map { "\($0)°" } ?? "")
                    .foregroundStyle(tempColor).frame(width: 26, alignment: .trailing)
                Text(gpu.power.map { String(format: "%.0fW", $0) } ?? "")
                    .foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
            }
            .font(.system(size: 11)).monospacedDigit()

            let procs = gpu.procs.filter { !onlyMine || $0.user == me }
            ForEach(procs) { p in
                ProcRow(p: p, mine: p.user == me)
            }
        }
    }

    private var tempColor: Color {
        guard let t = gpu.temp else { return .secondary }
        return t >= 85 ? .red : (t >= 78 ? .orange : .secondary)
    }
}

struct Meter: View {
    let fraction: Double
    let tint: Color
    let label: String
    let labelWidth: CGFloat

    var body: some View {
        HStack(spacing: 5) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.1))
                    Capsule().fill(tint.opacity(0.85))
                        .frame(width: max(0, min(1, fraction)) * geo.size.width)
                }
            }
            .frame(height: 6)
            Text(label).frame(width: labelWidth, alignment: .trailing)
        }
    }
}

struct ProcRow: View {
    let p: GPUProc
    let mine: Bool
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(p.user)
                    .font(.system(size: 11, weight: mine ? .semibold : .regular))
                    .foregroundStyle(mine ? Color.accentColor : Color.secondary)
                    .lineLimit(1).frame(width: 62, alignment: .leading)
                Text(p.prettyCommand)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(mine ? Color.primary : Color.secondary)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Group {
                    Text(p.gpuUtil.map { "\($0)%" } ?? "").frame(width: 32, alignment: .trailing)
                    Text(p.gpuMemMiB.map(Fmt.mib) ?? "").frame(width: 42, alignment: .trailing)
                    Text(p.elapsed.map(Fmt.elapsed) ?? "").frame(width: 54, alignment: .trailing)
                }
                .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
            }
            if expanded { details }
        }
        .padding(.leading, 22)
        .contentShape(Rectangle())
        .onTapGesture { expanded.toggle() }
        .help("Click for the full command, working directory and PID")
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let cwd = p.cwd { detail("cwd", cwd) }
            detail("cmd", p.args.isEmpty ? "(not visible)" : p.args)
            detail("pid", "\(p.pid)"
                   + (p.cpu.map { String(format: "   CPU %.0f%%", $0) } ?? "")
                   + (p.rssKB.map { "   RAM " + Fmt.mib($0 / 1024) } ?? ""))
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 5))
    }

    private func detail(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(key).foregroundStyle(.tertiary).frame(width: 24, alignment: .leading)
            Text(value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 10, design: .monospaced))
    }
}

struct SettingsView: View {
    let store: Store
    let onDone: () -> Void
    @State private var newHost = ""
    @State private var known = SSH.configHosts()
    @State private var configText = Self.displayPath(SSH.effectiveConfigPath)

    private static let intervals: [Double] = [2, 5, 10, 30, 60]

    private static func displayPath(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("SSH config file").font(.system(size: 12, weight: .semibold))
                HStack {
                    TextField(Self.displayPath(SSH.defaultConfigPath), text: $configText)
                        .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                        .onSubmit { applyConfig(configText) }
                    Button("Choose…", action: chooseConfig)
                    Button("Reset") { applyConfig(nil) }.disabled(SSH.customConfigPath == nil)
                }
                Text(configStatus).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("Servers").font(.system(size: 12, weight: .semibold))
                Text("Tick the hosts to watch.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                ForEach(allHosts, id: \.self) { h in
                    HStack {
                        Toggle(h, isOn: Binding(get: { store.hosts.contains(h) },
                                                set: { store.setHost(h, enabled: $0) }))
                            .font(.system(size: 12))
                        Spacer()
                        if store.savedPasswords.contains(h) {
                            PillButton(title: "Forget password") { store.forgetPassword(for: h) }
                        }
                    }
                }
                HStack {
                    TextField("user@host or ssh alias", text: $newHost)
                        .textFieldStyle(.roundedBorder).font(.system(size: 12))
                        .onSubmit(add)
                    Button("Add", action: add).disabled(!SSH.isValidHost(newHost))
                }
            }
            Divider()
            HStack {
                Text("Refresh every").font(.system(size: 12))
                Picker("", selection: Binding(get: { store.interval }, set: { store.setInterval($0) })) {
                    ForEach(Self.intervals, id: \.self) { Text("\(Int($0))s").tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            Toggle("Launch at login", isOn: Binding(get: { store.launchAtLogin },
                                                    set: { store.setLaunchAtLogin($0) }))
                .font(.system(size: 12))
            HStack {
                Button("Quit GPU Watcher") { NSApplication.shared.terminate(nil) }
                Spacer()
                Button("Done", action: onDone).keyboardShortcut(.defaultAction)
            }
        }
    }

    private var allHosts: [String] {
        known + store.hosts.filter { !known.contains($0) }
    }

    private var configStatus: String {
        _ = store.configRevision   // re-evaluate after the path changes
        let path = SSH.effectiveConfigPath
        guard FileManager.default.isReadableFile(atPath: path) else {
            return "File not found: \(Self.displayPath(path))"
        }
        let custom = SSH.customConfigPath != nil
        return "\(known.count) host\(known.count == 1 ? "" : "s") found" + (custom ? "" : " (default file)")
    }

    private func applyConfig(_ path: String?) {
        store.setConfigPath(path)
        configText = Self.displayPath(SSH.effectiveConfigPath)
        known = SSH.configHosts()
    }

    private func chooseConfig() {
        let panel = NSOpenPanel()
        panel.title = "Choose an SSH config file"
        panel.showsHiddenFiles = true          // ~/.ssh is hidden
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: (SSH.effectiveConfigPath as NSString).deletingLastPathComponent)
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { applyConfig(url.path) }
    }

    private func add() {
        let h = newHost.trimmingCharacters(in: .whitespaces)
        guard SSH.isValidHost(h) else { return }
        store.setHost(h, enabled: true)
        newHost = ""
    }
}
