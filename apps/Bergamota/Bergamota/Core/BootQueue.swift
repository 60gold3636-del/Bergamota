import Foundation
import Observation

struct QueueItem: Identifiable, Hashable {
    enum Status: Hashable { case pending, sending, sent, failed }
    let id = UUID()
    var imagePath: String
    var label: String = ""
    var status: Status = .pending
    var sentAt: Date?
    var output = ""
    var name: String { label.isEmpty ? (imagePath as NSString).lastPathComponent : label }
    var fileName: String { (imagePath as NSString).lastPathComponent }
}

/// Sends exactly ONE `fastboot boot <img>` per fastboot appearance. A failed send is never retried:
/// the phone has to leave fastboot (user re-enters it) before the next item is armed.
@Observable
@MainActor
final class BootQueue {
    var items: [QueueItem] = []
    var armed = false
    var waitingForLeave = false
    var lastSendFailed = false
    var recoveryRebootSent = false
    var note: String?

    @ObservationIgnored private var fastbootStreak = 0
    @ObservationIgnored private var nonFastbootStreak = 0
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let monitor: PhoneMonitor

    init(settings: AppSettings, monitor: PhoneMonitor) {
        self.settings = settings
        self.monitor = monitor
        monitor.observers.append { [weak self] old, new in self?.handle(old: old, new: new) }
    }

    var pending: [QueueItem] { items.filter { $0.status == .pending } }
    var sending: QueueItem? { items.first { $0.status == .sending } }

    func add(_ path: String, label: String = "") { items.append(QueueItem(imagePath: path, label: label)) }
    func remove(_ id: UUID) { items.removeAll { $0.id == id && $0.status != .sending } }
    func clearFinished() { items.removeAll { $0.status == .sent || $0.status == .failed } }
    func move(_ id: UUID, by d: Int) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let j = i + d
        guard items.indices.contains(j), items[i].status == .pending, items[j].status == .pending else { return }
        items.swapAt(i, j)
    }

    func arm() {
        armed = true
        note = nil
        if settings.notifyOnBoot || settings.notifyOnIOS { Notifier.requestAuthorization() }
    }
    func disarm() { armed = false }

    var statusText: String {
        if !armed { return pending.isEmpty ? "Queue is empty." : "Queue stopped. Press Start to arm it." }
        if let s = sending { return "Sending \(s.name) ..." }
        if pending.isEmpty { return "Queue is empty." }
        if waitingForLeave {
            return lastSendFailed
                ? "Send failed. ABL may be hung: re-enter fastboot (hold Power + Volume Down). Next item arms once the phone leaves fastboot."
                : "Boot sent. Waiting for the phone to leave fastboot before arming the next item."
        }
        switch monitor.state {
        case .fastboot: return "Phone is in fastboot. Confirming, then sending exactly one boot."
        case .recovery:
            return settings.rebootFromRecovery ? "In OrangeFox. Rebooting to bootloader (once)."
                : "Phone is in OrangeFox. Reboot to bootloader, or hold Power + Volume Down."
        case .ios, .iosBooting, .android: return "Waiting for fastboot. Hold Power + Volume Down."
        default: return "Waiting for fastboot. Hold Power + Volume Down."
        }
    }

    private func handle(old: PhoneState, new: PhoneState) {
        if new == .fastboot { fastbootStreak += 1; nonFastbootStreak = 0 }
        else {
            fastbootStreak = 0; nonFastbootStreak += 1
            if waitingForLeave && nonFastbootStreak >= 3 { waitingForLeave = false; lastSendFailed = false }
        }
        if new != .recovery { recoveryRebootSent = false }
        if settings.notifyOnIOS && new == .ios && old != .ios && old != .unknown { Notifier.post("Bergamota", "iOS is up on the Poco F1.") }

        guard armed, sending == nil, !pending.isEmpty else { return }

        if new == .recovery, settings.rebootFromRecovery, !recoveryRebootSent {
            recoveryRebootSent = true
            Task { await rebootToBootloader() }
            return
        }
        if new == .fastboot, !waitingForLeave, fastbootStreak >= 2 { Task { await sendNext() } }
    }

    private func rebootToBootloader() async {
        guard let adb = settings.adb else { note = "adb not found"; return }
        var args: [String] = []
        if let s = monitor.adbSerial { args += ["-s", s] }
        args += ["reboot", "bootloader"]
        let r = await Shell.run(adb, args, timeout: 15)
        note = "adb reboot bootloader: " + (r.ok ? "sent" : "failed (\(r.combined.trimmingCharacters(in: .whitespacesAndNewlines)))")
    }

    private func sendNext() async {
        guard sending == nil, !waitingForLeave, let idx = items.firstIndex(where: { $0.status == .pending }) else { return }
        guard let fb = settings.fastboot else { note = "fastboot not found"; return }
        // Latch first: whatever happens, no second send until the phone leaves fastboot.
        waitingForLeave = true
        lastSendFailed = false
        items[idx].status = .sending
        let path = items[idx].imagePath
        let id = items[idx].id
        var args: [String] = []
        if let s = monitor.fastbootSerial { args += ["-s", s] }
        args += ["boot", path]
        guard FileManager.default.fileExists(atPath: path) else {
            finish(id, ok: false, output: "image not found: \(path)")
            return
        }
        let r = await Shell.run(fb, args, timeout: 180)
        var out = "$ fastboot " + args.map(shellQuote).joined(separator: " ") + "\n" + r.combined
        if r.timedOut { out += "\n[timed out]" }
        if let e = r.launchError { out += "\n\(e)" }
        finish(id, ok: r.ok, output: out)
    }

    private func finish(_ id: UUID, ok: Bool, output: String) {
        if let i = items.firstIndex(where: { $0.id == id }) {
            items[i].status = ok ? .sent : .failed
            items[i].sentAt = Date()
            items[i].output = output
            lastSendFailed = !ok
            if settings.notifyOnBoot {
                Notifier.post("Bergamota", ok ? "fastboot boot sent: \(items[i].name)" : "fastboot boot FAILED: \(items[i].name). Re-enter fastboot.")
            }
        }
        nonFastbootStreak = 0
        if pending.isEmpty { armed = false }
    }
}
