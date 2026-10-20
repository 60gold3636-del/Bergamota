import Foundation
import Observation

enum PhoneState: String, Sendable {
    case unknown, offline, fastboot, recovery, android, iosBooting, ios

    var title: String {
        switch self {
        case .unknown: "Checking..."
        case .offline: "Offline"
        case .fastboot: "Fastboot"
        case .recovery: "OrangeFox / Recovery"
        case .android: "Android (adb)"
        case .iosBooting: "iOS booting"
        case .ios: "iOS"
        }
    }
    var symbol: String {
        switch self {
        case .unknown: "ellipsis.circle"
        case .offline: "bolt.slash"
        case .fastboot: "bolt.horizontal.circle.fill"
        case .recovery: "wrench.and.screwdriver.fill"
        case .android: "android.fill"
        case .iosBooting: "hourglass"
        case .ios: "apple.logo"
        }
    }
}

struct IOSInfo: Equatable, Sendable {
    var uname = ""
    var bootDate: Date?
    var uptime: TimeInterval?
    var batteryPercent: Int?
    var isCharging: Bool?
    var powerSource: String?
    var fetched = Date()
}

private struct Probe: Sendable {
    var fastbootSerial: String?
    var adbSerial: String?
    var adbState: String?
    var iface: String?
    var ifaceUp = false
    var ping = false
    var ssh = false
    var nat: String?
    var errors: [String] = []
}

@Observable
@MainActor
final class PhoneMonitor {
    nonisolated static let usbMAC = "02:00:5e:77:ee:01"

    var state: PhoneState = .unknown
    var stateSince = Date()
    var fastbootSerial: String?
    var adbSerial: String?
    var adbState: String?
    var ifaceName: String?
    var ifaceUp = false
    var pingOK = false
    var sshOpen = false
    var natForwarding: String?
    var info: IOSInfo?
    var infoError: String?
    var toolWarnings: [String] = []
    var lastPoll: Date?

    /// Called on the main actor after every poll with (previous, new) state.
    @ObservationIgnored var observers: [(PhoneState, PhoneState) -> Void] = []
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var infoInFlight = false
    @ObservationIgnored private let settings: AppSettings

    init(settings: AppSettings) { self.settings = settings }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                let began = Date()
                await self?.pollOnce()
                let elapsed = Date().timeIntervalSince(began)
                try? await Task.sleep(nanoseconds: UInt64(max(0.2, 2.0 - elapsed) * 1e9))
            }
        }
    }

    func pollOnce() async {
        let fb = settings.fastboot, adb = settings.adb, ip = settings.phoneIP
        let probe = await Self.probe(fastboot: fb, adb: adb, ip: ip)
        apply(probe)
        if state == .ios { await refreshInfoIfNeeded() }
    }

    private func apply(_ p: Probe) {
        var warnings: [String] = []
        if settings.fastboot == nil { warnings.append("fastboot not found (set it in Settings)") }
        if settings.adb == nil { warnings.append("adb not found (set it in Settings)") }
        toolWarnings = warnings
        fastbootSerial = p.fastbootSerial
        adbSerial = p.adbSerial
        adbState = p.adbState
        ifaceName = p.iface
        ifaceUp = p.ifaceUp
        pingOK = p.ping
        sshOpen = p.ssh
        natForwarding = p.nat
        lastPoll = Date()

        let new: PhoneState
        if p.fastbootSerial != nil { new = .fastboot }
        else if let s = p.adbState, s == "recovery" || s == "sideload" { new = .recovery }
        else if p.iface != nil && p.ifaceUp && p.ping && p.ssh { new = .ios }
        else if p.adbState == "device" { new = .android }
        else if p.iface != nil && p.ifaceUp { new = .iosBooting }
        else { new = .offline }

        let old = state
        if new != old {
            state = new
            stateSince = Date()
            if new != .ios { info = nil; infoError = nil }
        }
        for o in observers { o(old, new) }
    }

    // MARK: probing

    private nonisolated static func probe(fastboot: String?, adb: String?, ip: String) async -> Probe {
        async let fbR: ShellResult? = fastboot != nil ? Shell.run(fastboot!, ["devices"], timeout: 3) : nil
        async let adbR: ShellResult? = adb != nil ? Shell.run(adb!, ["devices"], timeout: 4) : nil
        async let ifR = Shell.run("/sbin/ifconfig", ["-a"], timeout: 3)
        async let natR = Shell.run("/usr/sbin/sysctl", ["-n", "net.inet.ip.forwarding"], timeout: 2)
        var p = Probe()
        if let r = await fbR, r.ok {
            for line in r.stdout.split(whereSeparator: \.isNewline) {
                let f = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
                if f.count >= 2, f[1] == "fastboot" || f[1] == "fastbootd" { p.fastbootSerial = String(f[0]); break }
            }
        }
        if let r = await adbR, r.ok {
            for line in r.stdout.split(whereSeparator: \.isNewline) {
                if line.hasPrefix("*") || line.hasPrefix("List of") { continue }
                let f = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
                if f.count >= 2 { p.adbSerial = String(f[0]); p.adbState = String(f[1]); break }
            }
        }
        let ifr = await ifR
        if let (name, up) = parseInterface(ifr.stdout, mac: usbMAC) { p.iface = name; p.ifaceUp = up }
        let nat = await natR
        if nat.ok { p.nat = nat.stdout.trimmingCharacters(in: .whitespacesAndNewlines) }
        if p.iface != nil && p.ifaceUp {
            async let pingR = Shell.run("/sbin/ping", ["-c", "1", "-W", "1000", ip], timeout: 3)
            async let sshR = Task.detached { Shell.tcpOpen(host: ip, port: 22, timeout: 1.0) }.value
            p.ping = await pingR.ok
            p.ssh = await sshR
        }
        return p
    }

    nonisolated static func parseInterface(_ text: String, mac: String) -> (String, Bool)? {
        var blocks: [[String]] = []
        for line in text.split(separator: "\n") {
            if let f = line.first, !f.isWhitespace { blocks.append([String(line)]) }
            else if !blocks.isEmpty { blocks[blocks.count - 1].append(String(line)) }
        }
        let needle = "ether \(mac.lowercased())"
        for b in blocks where b.contains(where: { $0.lowercased().contains(needle) }) {
            let head = b[0]
            let name = String(head.prefix(while: { $0 != ":" }))
            var flagsUp = false
            if let lt = head.firstIndex(of: "<"), let gt = head.firstIndex(of: ">"), lt < gt {
                flagsUp = head[head.index(after: lt)..<gt].split(separator: ",").contains("UP")
            }
            var active = true
            if let st = b.first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("status:") }) {
                active = st.contains(" active")
            }
            return (name, flagsUp && active)
        }
        return nil
    }

    // MARK: iOS info over SSH

    func refreshInfoIfNeeded(force: Bool = false) async {
        guard state == .ios, !infoInFlight else { return }
        if !force, let i = info, Date().timeIntervalSince(i.fetched) < 10 { return }
        guard let ssh = settings.ssh else { infoError = "ssh not found"; return }
        infoInFlight = true
        defer { infoInFlight = false }
        let ip = settings.phoneIP
        let remote = "uname -a; echo '@@BOOT'; sysctl -n kern.boottime; echo '@@NOW'; date +%s; echo '@@PS'; /usr/local/bin/sweetps"
        let r = await Shell.run(ssh, ["-o", "BatchMode=yes", "-o", "ConnectTimeout=3", "root@\(ip)", remote], timeout: 10)
        if r.launchError != nil || r.timedOut || (r.status != 0 && r.stdout.isEmpty) {
            infoError = r.timedOut ? "ssh timed out" : (r.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "ssh failed (exit \(r.status))" : r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
            return
        }
        infoError = nil
        info = Self.parseInfo(r.stdout)
    }

    nonisolated static func parseInfo(_ out: String) -> IOSInfo {
        var parts: [String: String] = [:]
        var key = "UNAME"
        var buf: [String] = []
        for line in out.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("@@") {
                parts[key] = buf.joined(separator: "\n"); key = String(line.dropFirst(2)); buf = []
            } else { buf.append(String(line)) }
        }
        parts[key] = buf.joined(separator: "\n")
        var i = IOSInfo()
        i.uname = (parts["UNAME"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let boot = parts["BOOT"] ?? ""
        let nowS = Double((parts["NOW"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        if let m = boot.firstMatch(of: /sec\s*=\s*(\d+)/), let sec = Double(m.1) {
            i.bootDate = Date(timeIntervalSince1970: sec)
            let now = nowS ?? Date().timeIntervalSince1970
            i.uptime = max(0, now - sec)
        }
        let ps = parts["PS"] ?? ""
        if let m = ps.firstMatch(of: /"?Current Capacity"?\s*=\s*(\d+)/) { i.batteryPercent = Int(m.1) }
        if let m = ps.firstMatch(of: /"?Is Charging"?\s*=\s*"?(\w+)"?/) {
            let v = m.1.lowercased()
            i.isCharging = ["1", "true", "yes"].contains(v)
        }
        if let m = ps.firstMatch(of: /"?Power Source State"?\s*=\s*"?([^";\n]+)"?/) {
            i.powerSource = m.1.trimmingCharacters(in: .whitespaces)
        }
        return i
    }
}
