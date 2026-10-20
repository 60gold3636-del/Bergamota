import Foundation
import Observation

struct QueueItem: Identifiable, Hashable {
    enum Status: Hashable { case pending, sending, sent, failed }
    let id = UUID()
    var imagePath: String
    var label: String = ""
    var size: Int64 = 0
    var status: Status = .pending
    var sentAt: Date?
    var output = ""
    /// The auto-reboot into fastboot was tried for this item (at most once per item).
    var autoRebootTried = false
    /// The auto-reboot did not end in fastboot within 90 s (or could not be sent): enter fastboot by hand.
    var needsManualFastboot = false
    var name: String { label.isEmpty ? (imagePath as NSString).lastPathComponent : label }
    var isLarge: Bool { size > BootQueue.largeImageBytes }
    var fileName: String { (imagePath as NSString).lastPathComponent }
}

/// Sends exactly ONE `fastboot boot <img>` per fastboot appearance. A failed send is never retried:
/// the phone has to leave fastboot (user re-enters it) before the next item is armed.
@Observable
@MainActor
final class BootQueue {
    /// ABL silently failed to start a 206 MB boot image; warn above this size.
    nonisolated static let largeImageBytes: Int64 = 64 << 20
    static let largeWarning = "large boot image: ABL may not start it"
    static func fileSize(_ path: String) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? NSNumber)?.int64Value ?? 0
    }

    var items: [QueueItem] = []
    var armed = false
    var waitingForLeave = false
    var lastSendFailed = false
    var recoveryRebootSent = false
    var note: String?
    /// Auto-reboot (iOS -> fastboot) bookkeeping, see `autoRebootStep`.
    var rebootWatch: (id: UUID, at: Date)?
    var autoRebootBusy = false
    /// After a failed auto-reboot no further one is attempted until fastboot is seen, the queue is re-armed or the toggle is cycled.
    var autoSuspended = false
    static let autoMinIOSSeconds: TimeInterval = 30
    static let autoFastbootWaitSeconds: TimeInterval = 90

    @ObservationIgnored private var fastbootStreak = 0
    @ObservationIgnored private var nonFastbootStreak = 0
    @ObservationIgnored private var sentSession: String?
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let monitor: PhoneMonitor
    @ObservationIgnored private let tools: PhoneTools

    init(settings: AppSettings, monitor: PhoneMonitor, tools: PhoneTools) {
        self.settings = settings
        self.monitor = monitor
        self.tools = tools
        monitor.observers.append { [weak self] old, new in self?.handle(old: old, new: new) }
    }

    var pending: [QueueItem] { items.filter { $0.status == .pending } }
    var sending: QueueItem? { items.first { $0.status == .sending } }

    func add(_ path: String, label: String = "") { items.append(QueueItem(imagePath: path, label: label, size: Self.fileSize(path))) }
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
        autoSuspended = false
        if settings.notifyOnBoot || settings.notifyOnIOS { Notifier.requestAuthorization() }
    }
    func disarm() { armed = false; rebootWatch = nil }

    var statusText: String {
        if !armed { return pending.isEmpty ? "Queue is empty." : "Queue stopped. Press Start to arm it." }
        if let s = sending { return "Sending \(s.name) ..." }
        if pending.isEmpty { return "Queue is empty." }
        if waitingForLeave {
            return lastSendFailed
                ? "Send failed. ABL may be hung: re-enter fastboot (hold Power + Volume Down). Next item arms once the phone leaves fastboot or re-enumerates."
                : "Boot sent. Waiting for the phone to leave fastboot (or re-enumerate) before arming the next item."
        }
        switch monitor.state {
        case .fastboot: return "Phone is in fastboot. Confirming, then sending exactly one boot."
        case .recovery:
            return settings.rebootFromRecovery ? "In OrangeFox. Rebooting to bootloader (once)."
                : "Phone is in OrangeFox. Reboot to bootloader, or hold Power + Volume Down."
        case .ios, .iosBooting, .android: return autoStatusText ?? "Waiting for fastboot. Hold Power + Volume Down."
        default: return "Waiting for fastboot. Hold Power + Volume Down."
        }
    }

    /// State of the auto-reboot into fastboot, for the queue header (nil: feature off or nothing to say).
    var autoStatusText: String? {
        guard settings.autoRebootToFastboot, armed, let next = pending.first else { return nil }
        if next.needsManualFastboot {
            return "Needs manual fastboot: the automatic reboot of iOS did not reach fastboot. Hold Power + Volume Down."
        }
        if rebootWatch != nil || autoRebootBusy {
            return "Rebooting iOS into fastboot (waiting up to \(Int(Self.autoFastbootWaitSeconds)) s)."
        }
        if autoSuspended { return "Auto-reboot paused after a failed attempt. Enter fastboot by hand." }
        if monitor.state == .ios {
            let left = Int(Self.autoMinIOSSeconds - Date().timeIntervalSince(monitor.stateSince))
            return left > 0 ? "iOS is up. Auto-reboot into fastboot in about \(left) s." : "iOS is up. Rebooting into fastboot now."
        }
        return nil
    }

    var autoRebootBadge: String? {
        guard settings.autoRebootToFastboot else { return nil }
        return autoSuspended || pending.first?.needsManualFastboot == true ? "auto-reboot: manual fastboot needed" : "auto-reboot to fastboot on"
    }

    /// Reboots iOS into fastboot when the queue is armed, the next item is pending and the phone has been in iOS for
    /// >= 30 s; at most once per item. 90 s after the command without fastboot: the item is marked "needs manual fastboot".
    private func autoRebootStep(new: PhoneState) {
        if !settings.autoRebootToFastboot { autoSuspended = false }
        if new == .fastboot { autoSuspended = false; rebootWatch = nil }
        guard armed, sending == nil, let idx = items.firstIndex(where: { $0.status == .pending }) else { rebootWatch = nil; return }
        if let w = rebootWatch {
            guard let wi = items.firstIndex(where: { $0.id == w.id && $0.status == .pending }) else { rebootWatch = nil; return }
            if new != .fastboot, Date().timeIntervalSince(w.at) >= Self.autoFastbootWaitSeconds {
                rebootWatch = nil
                markNeedsManual(wi, "iOS reboot did not reach fastboot within \(Int(Self.autoFastbootWaitSeconds)) s")
            }
            return
        }
        guard settings.autoRebootToFastboot, new == .ios, !autoRebootBusy, !autoSuspended, !waitingForLeave,
              !items[idx].autoRebootTried, !items[idx].needsManualFastboot, tools.rebooting == nil, !tools.busy,
              Date().timeIntervalSince(monitor.stateSince) >= Self.autoMinIOSSeconds else { return }
        let id = items[idx].id
        items[idx].autoRebootTried = true
        autoRebootBusy = true
        note = "Auto-reboot: iOS -> fastboot for \(items[idx].name)."
        DebugLog.write("auto-reboot to fastboot for \(items[idx].name)")
        if settings.notifyOnBoot { Notifier.post("Bergamota", "Rebooting iOS into fastboot for \(items[idx].name).") }
        Task {
            let (ok, msg) = await tools.rebootIOS(to: "fastboot")
            autoRebootBusy = false
            guard let i = items.firstIndex(where: { $0.id == id }) else { return }
            if ok { rebootWatch = (id, Date()); note = "Auto-reboot sent. Waiting for fastboot." }
            else { markNeedsManual(i, msg) }
        }
    }

    private func markNeedsManual(_ i: Int, _ why: String) {
        items[i].needsManualFastboot = true
        autoSuspended = true
        note = "Needs manual fastboot (\(items[i].name)): \(why)"
        DebugLog.write("auto-reboot failed: \(why)")
        if settings.notifyOnBoot { Notifier.post("Bergamota", "Needs manual fastboot: \(why)") }
    }

    private func handle(old: PhoneState, new: PhoneState) {
        if new == .fastboot { fastbootStreak += 1; nonFastbootStreak = 0 }
        else {
            fastbootStreak = 0; nonFastbootStreak += 1
            // One poll away from fastboot is enough: a bad image leaves ABL in fastboot, so the absence can be short.
            if waitingForLeave && nonFastbootStreak >= 1 { waitingForLeave = false; lastSendFailed = false }
        }
        // Still in fastboot but re-enumerated on USB (force restart into fastboot between two polls): a new appearance.
        if new == .fastboot, waitingForLeave, let s = monitor.fastbootSession, let old = sentSession, s != old {
            waitingForLeave = false; lastSendFailed = false; fastbootStreak = 1
        }
        if new != .recovery { recoveryRebootSent = false }
        if settings.notifyOnIOS && new == .ios && old != .ios && old != .unknown { Notifier.post("Bergamota", "iOS is up on the Poco F1.") }

        autoRebootStep(new: new)
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

    /// Manual send of the next pending item, ignoring the leave-fastboot latch. Only while the phone is in fastboot.
    /// Returns a short result for the caller (UI or remote request).
    func sendNow() async -> String {
        guard monitor.state == .fastboot else { return "phone is not in fastboot" }
        guard sending == nil else { return "a send is already in progress" }
        guard !pending.isEmpty else { return "queue has nothing pending" }
        let id = pending[0].id
        await sendNext(force: true)
        let r = items.first { $0.id == id && ($0.status == .sent || $0.status == .failed) }
        return r.map { "\($0.status == .sent ? "sent" : "FAILED"): \($0.name)" } ?? "not sent"
    }

    private func sendNext(force: Bool = false) async {
        guard sending == nil, force || !waitingForLeave, let idx = items.firstIndex(where: { $0.status == .pending }) else { return }
        guard let fb = settings.fastboot else { note = "fastboot not found"; return }
        // Latch first: whatever happens, no second send until the phone leaves fastboot.
        waitingForLeave = true
        sentSession = monitor.fastbootSession
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
