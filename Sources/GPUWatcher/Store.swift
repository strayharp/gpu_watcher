import Foundation
import Observation
import ServiceManagement

@MainActor
@Observable
final class Store {
    private(set) var hosts: [String]
    private(set) var interval: Double
    private(set) var states: [String: HostState] = [:]
    /// Hosts with an SSH password saved in the keychain.
    private(set) var savedPasswords: Set<String> = []
    /// Hosts whose saved password failed; it is not tried again until the user re-enters it.
    private(set) var rejectedPasswords: Set<String> = []
    var onlyMine: Bool {
        didSet { defaults.set(onlyMine, forKey: "onlyMine") }
    }

    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored let isDemo: Bool

    init(demo: Bool = false) {
        isDemo = demo
        if demo {
            hosts = Demo.hosts
            interval = 5
            onlyMine = false
            states = Demo.states()
            return
        }
        hosts = (defaults.stringArray(forKey: "hosts") ?? []).filter(SSH.isValidHost)
        let saved = defaults.double(forKey: "interval")
        interval = saved > 0 ? saved : 5
        onlyMine = defaults.bool(forKey: "onlyMine")
        savedPasswords = Set(hosts.filter(Keychain.has))
        for h in hosts { spawn(h) }
    }

    // MARK: Summary

    var allGPUs: [GPUInfo] {
        hosts.flatMap { states[$0]?.snapshot?.gpus ?? [] }
    }

    /// "busy/total" across every reachable server; empty until something has been fetched.
    var menuTitle: String {
        let g = allGPUs
        return g.isEmpty ? "" : "\(g.filter(\.isBusy).count)/\(g.count)"
    }

    // MARK: Settings

    func setHost(_ host: String, enabled: Bool) {
        guard SSH.isValidHost(host), !isDemo else { return }
        if enabled, !hosts.contains(host) {
            hosts.append(host)
            if Keychain.has(host: host) { savedPasswords.insert(host) }
            spawn(host)
        } else if !enabled {
            hosts.removeAll { $0 == host }
            tasks.removeValue(forKey: host)?.cancel()
            states[host] = nil
            forgetPassword(for: host)
        }
        defaults.set(hosts, forKey: "hosts")
    }

    /// Bumped whenever the ssh config path changes, so views re-read the host list.
    private(set) var configRevision = 0

    /// Pass nil or an empty string to go back to ssh's default (~/.ssh/config).
    func setConfigPath(_ path: String?) {
        guard !isDemo else { return }
        let trimmed = path?.trimmingCharacters(in: .whitespaces) ?? ""
        let expanded = (trimmed as NSString).expandingTildeInPath
        if trimmed.isEmpty || expanded == SSH.defaultConfigPath {
            defaults.removeObject(forKey: SSH.configPathKey)
        } else {
            defaults.set(expanded, forKey: SSH.configPathKey)
        }
        configRevision += 1
        refreshAll()   // host aliases may now resolve differently
    }

    func setInterval(_ value: Double) {
        interval = value
        defaults.set(value, forKey: "interval")
        refreshAll()
    }

    var launchAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("GPUWatcher: launch-at-login change failed: \(error)")
        }
    }

    // MARK: Saved passwords

    /// Stores the password in the keychain and logs in with it right away.
    func savePassword(_ password: String, for host: String) {
        guard !isDemo, !password.isEmpty, Keychain.set(password, host: host) else { return }
        savedPasswords.insert(host)
        rejectedPasswords.remove(host)
        refresh(host)
    }

    func forgetPassword(for host: String) {
        guard !isDemo else { return }
        Keychain.delete(host: host)
        savedPasswords.remove(host)
        rejectedPasswords.remove(host)
    }

    // MARK: Polling

    func refreshAll() {
        for h in hosts { refresh(h) }
    }

    /// Restart polling for one host right now (also used as "retry").
    func refresh(_ host: String) {
        guard !isDemo else { return }
        tasks.removeValue(forKey: host)?.cancel()
        if case .auth? = states[host]?.error { states[host]?.error = nil }   // force one real attempt
        spawn(host)
    }

    private func spawn(_ host: String) {
        tasks[host] = Task { [weak self] in await self?.loop(host) }
    }

    private func canUseSavedPassword(_ host: String) -> Bool {
        savedPasswords.contains(host) && !rejectedPasswords.contains(host)
    }

    private func loop(_ host: String) async {
        while !Task.isCancelled {
            var delay = interval
            // A host that rejected key auth is not blindly retried over the network (repeated failures look
            // like a brute-force attempt and can lock the account). Either a shared connection has appeared
            // since (Terminal login), or we make exactly one attempt with the saved password, or we wait.
            var usePassword = false
            var waitingForLogin = false
            if case .auth? = states[host]?.error, !(await SSH.masterAlive(host)) {
                if canUseSavedPassword(host) { usePassword = true } else { waitingForLogin = true }
            }
            if !waitingForLogin {
                let result = await SSH.probe(host: host, withSavedPassword: usePassword)
                if Task.isCancelled { return }
                var st = states[host] ?? HostState()
                switch result {
                case .success(let snap):
                    st.snapshot = snap
                    st.error = nil
                    st.updated = Date()
                case .failure(let e):
                    st.error = e
                    if case .unreachable = e { delay = max(interval, 30) }
                    if case .auth = e {
                        if usePassword {
                            rejectedPasswords.insert(host)
                        } else if canUseSavedPassword(host) {
                            delay = 0   // go straight to the saved-password attempt
                        }
                    }
                }
                states[host] = st
            }
            try? await Task.sleep(for: .seconds(delay))
        }
    }
}
