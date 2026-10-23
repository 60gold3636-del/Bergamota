import Foundation
import CryptoKit
import Observation

/// THE ONE EXCEPTION to "Bergamota never flashes": `fastboot flash userdata <img>` for the iOS root image.
/// The partition name is a literal below; nothing in the app accepts a partition from the user, a request or a file.
/// No other partition can be flashed, erased or formatted, and there is no `erase`, `format` or `oem` anywhere.
enum UserdataFlash {
    /// The only partition this app will ever pass to `fastboot flash`.
    static let partition = "userdata"
    /// Anything smaller is certainly not a root image.
    static let minBytes: Int64 = 64 << 20
    static let confirmWord = "userdata"

    /// The only partitions the app may flash: the iOS root (userdata), Enxerto's boot image (boot) and the
    /// splash (logo). Never bootloaders, recovery, modem, persist, dsp, bluetooth or anything else.
    static let partitions = ["userdata", "boot", "logo"]

    /// The complete argument list of the flash command. Only this function builds it.
    static func flashArguments(serial: String, image: String, partition: String = "userdata") -> [String] {
        precondition(partitions.contains(partition), "refusing to flash \(partition)")
        // Always chunk explicitly: when fastboot could not read ABL's max-download-size it sent a 3 GB
        // userdata image in one transfer and USB failed (usb_write e00002c0). 512 MiB sparse chunks worked.
        return ["-s", serial, "-S", "512M", "flash", partition, image]
    }

    struct Info { var path: String; var name: String; var size: Int64; var partition: String = "userdata" }

    /// Absolute path of an existing regular `.img`/`.simg` file of at least 64 MiB.
    static func validate(_ rawPath: String, partition: String = "userdata") -> Result<Info, UserdataFlashError> {
        guard partitions.contains(partition) else { return .failure(.init("partition \(partition) can not be flashed by Bergamota")) }
        let path = URL(fileURLWithPath: (rawPath as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath().path
        guard rawPath.hasPrefix("/") || rawPath.hasPrefix("~") else { return .failure(.init("image path must be absolute")) }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else { return .failure(.init("\(rawPath) does not exist")) }
        let ext = (path as NSString).pathExtension.lowercased()
        guard ext == "img" || ext == (partition == "userdata" ? "simg" : "img") else { return .failure(.init("\(rawPath) must be a .img\(partition == "userdata" ? " or .simg" : "") file")) }
        let size = ((try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? NSNumber)?.int64Value ?? 0
        let name = (path as NSString).lastPathComponent
        switch partition {
        case "boot":
            // Enxerto's boot.img: Android header, fits the 64 MiB boot partition
            guard size >= 1 << 20, size <= 64 << 20 else { return .failure(.init("\(name): a boot image must be 1-64 MiB")) }
            guard let h = FileHandle(forReadingAtPath: path), let magic = try? h.read(upToCount: 8), String(decoding: magic, as: UTF8.self) == "ANDROID!" else {
                return .failure(.init("\(name) is not an Android boot image (no ANDROID! header)"))
            }
        case "logo":
            guard size >= 1 << 20, size <= 32 << 20 else { return .failure(.init("\(name): a logo image must be 1-32 MiB")) }
        default:
            guard size >= minBytes else { return .failure(.init("\(name) is only \(size) bytes (< 64 MiB): not a root image")) }
        }
        return .success(Info(path: path, name: name, size: size, partition: partition))
    }

    /// Streaming SHA-256 (hex), off the main thread.
    static func sha256(_ path: String) async -> String? {
        await Task.detached(priority: .utility) {
            guard let h = FileHandle(forReadingAtPath: path) else { return nil }
            defer { try? h.close() }
            var hasher = SHA256()
            while true {
                guard let d = try? h.read(upToCount: 4 << 20), !d.isEmpty else { break }
                hasher.update(data: d)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }

    /// Last `Sending sparse 'userdata' n/m` (or `Sending 'userdata'` => 1/1) in fastboot output.
    nonisolated static func progress(in text: String) -> (Int, Int)? {
        guard let re = try? NSRegularExpression(pattern: "Sending sparse '?[A-Za-z_]+'? (\\d+)/(\\d+)") else { return nil }
        let ns = text as NSString
        guard let m = re.matches(in: text, range: NSRange(location: 0, length: ns.length)).last,
              let a = Int(ns.substring(with: m.range(at: 1))), let b = Int(ns.substring(with: m.range(at: 2))) else { return nil }
        return (a, b)
    }
}

struct UserdataFlashError: Error { let message: String; init(_ m: String) { message = m } }

/// Runs the flash and publishes progress for the banner, the Boot page and status.json.
@Observable
@MainActor
final class UserdataFlasher {
    var active = false
    var fileName = ""
    /// Partition of the current / last flash (userdata, boot or logo).
    var partition = "userdata"
    var current = 0
    var total = 0
    var output = ""
    /// For the progress bar / ETA: when the flash started, the image size, and when the chunk before
    /// `current` finished (fastboot only reports per sparse chunk, so the bar interpolates inside one).
    var startedAt: Date?
    var bytes: Int64 = 0
    var lastChunkDoneAt: Date?
    /// Outcome of the last flash (ok, when, message).
    var last: (ok: Bool, at: Date, message: String)?

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let monitor: PhoneMonitor
    init(settings: AppSettings, monitor: PhoneMonitor) { self.settings = settings; self.monitor = monitor }

    var progressText: String { total > 0 ? "\(current)/\(total)" : "starting" }

    /// 0...1, or nil until the first sparse chunk is done (no rate known yet).
    func fraction(now: Date = Date()) -> Double? {
        guard active, total > 0, current >= 1, let t0 = startedAt else { return nil }
        let done = Double(current - 1)
        guard done > 0, let last = lastChunkDoneAt else { return nil }
        let perChunk = last.timeIntervalSince(t0) / done
        let inChunk = perChunk > 0 ? min(0.97, now.timeIntervalSince(last) / perChunk) : 0
        return min(1, (done + inChunk) / Double(total))
    }

    /// "37%  |  4.1 of 11.0 GB  |  48 MB/s  |  ETA 3:12", or nil before a rate is known.
    func progressDetail(now: Date = Date()) -> String? {
        guard let f = fraction(now: now), f > 0, let t0 = startedAt else { return nil }
        let elapsed = now.timeIntervalSince(t0)
        let gb = { (b: Double) in String(format: "%.1f", b / 1_073_741_824) }
        let sent = Double(bytes) * f
        let rate = sent / max(elapsed, 1) / 1_048_576
        return "\(Int(f * 100))%  |  \(gb(sent)) of \(gb(Double(bytes))) GB  |  \(Int(rate)) MB/s  |  ETA \(formatElapsed(elapsed / f - elapsed))"
    }

    /// ONE `fastboot -s <serial> flash userdata <img>`. No retry. Caller must have checked fastboot state and queue busy.
    func flash(_ info: UserdataFlash.Info) async -> (ok: Bool, message: String) {
        guard !active else { return (false, "a flash is already running") }
        guard let fb = settings.fastboot else { return (false, "fastboot not found") }
        guard let serial = monitor.fastbootSerial, !serial.isEmpty else { return (false, "no fastboot serial") }
        active = true
        fileName = info.name; current = 0; total = 0
        startedAt = Date(); bytes = info.size; lastChunkDoneAt = nil
        let args = UserdataFlash.flashArguments(serial: serial, image: info.path, partition: info.partition)
        partition = info.partition
        output = "$ fastboot " + args.map(shellQuote).joined(separator: " ") + "\n"
        DebugLog.write("FLASH userdata start \(info.path) (\(info.size) bytes)")
        let box = FlashTail()
        let r = await Shell.run(fb, args, timeout: 7200, onOutput: { [weak self] chunk in
            let tail = box.append(chunk)
            let p = UserdataFlash.progress(in: tail)
            Task { @MainActor in
                guard let self else { return }
                self.output += chunk
                if self.output.count > 200_000 { self.output = String(self.output.suffix(100_000)) }
                if let p {
                    if p.0 != self.current, p.0 > 1 { self.lastChunkDoneAt = Date() }
                    self.current = p.0; self.total = p.1
                }
            }
        })
        var ok = r.ok
        var msg = "FLASHED \(info.partition) (\(info.name))"
        if r.combined.contains("FAILED") { ok = false }
        if !ok {
            msg = "FAILED flashing \(info.partition): " + (r.launchError ?? (r.timedOut ? "timed out" : "fastboot exit \(r.status)"))
        }
        if let e = r.launchError { output += "\n\(e)" }
        output += "\n" + msg + "\n"
        active = false
        last = (ok, Date(), msg)
        DebugLog.write(msg)
        return (ok, msg)
    }
}

private final class FlashTail: @unchecked Sendable {
    private let lock = NSLock()
    private var s = ""
    func append(_ c: String) -> String { lock.lock(); defer { lock.unlock() }; s += c; if s.count > 4096 { s = String(s.suffix(2048)) }; return s }
}
