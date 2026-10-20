import Foundation
import Observation

@Observable
@MainActor
final class AppSettings {
    static let defaultRepo = "/Users/zesmoi/git/iAndroid/ios-beryllium"
    @ObservationIgnored private let d = UserDefaults.standard

    var repoPath: String { didSet { d.set(repoPath, forKey: "repoPath") } }
    var phoneIP: String { didSet { d.set(phoneIP, forKey: "phoneIP") } }
    var fastbootPath: String { didSet { d.set(fastbootPath, forKey: "fastbootPath") } }
    var adbPath: String { didSet { d.set(adbPath, forKey: "adbPath") } }
    var ghPath: String { didSet { d.set(ghPath, forKey: "ghPath") } }
    var pythonPath: String { didSet { d.set(pythonPath, forKey: "pythonPath") } }
    var sshPath: String { didSet { d.set(sshPath, forKey: "sshPath") } }
    var ghRepo: String { didSet { d.set(ghRepo, forKey: "ghRepo") } }
    var rebootFromRecovery: Bool { didSet { d.set(rebootFromRecovery, forKey: "rebootFromRecovery") } }
    var notifyOnBoot: Bool { didSet { d.set(notifyOnBoot, forKey: "notifyOnBoot") } }
    var allowRemoteStart: Bool { didSet { d.set(allowRemoteStart, forKey: "allowRemoteStart") } }
    var autoSaveLog: Bool { didSet { d.set(autoSaveLog, forKey: "autoSaveLog") } }
    var notifyOnIOS: Bool { didSet { d.set(notifyOnIOS, forKey: "notifyOnIOS") } }
    /// Reboot the phone from iOS into fastboot (SSH `sweetreboot fastboot`) when a queued image is waiting.
    var autoRebootToFastboot: Bool { didSet { d.set(autoRebootToFastboot, forKey: "autoRebootToFastboot") } }

    /// Prefer Bergamota fastboot (our shim's) over ABL fastboot for the automatic reboot of queued boots; falls back to ABL when `sweetreboot bergamota` fails.
    var preferBergamotaFastboot: Bool { didSet { d.set(preferBergamotaFastboot, forKey: "preferBergamotaFastboot") } }
    /// Image `fastboot boot`ed from ABL fastboot by "Enter Bergamota fastboot".
    var bergamotaImagePath: String { didSet { d.set(bergamotaImagePath, forKey: "bergamotaImagePath") } }
    static let defaultBergamotaImage = "/Users/zesmoi/git/iAndroid/ios-beryllium-ios18/shim/out/bergamota-fastboot.img"

    init() {
        let d = UserDefaults.standard
        repoPath = d.string(forKey: "repoPath") ?? Self.defaultRepo
        phoneIP = d.string(forKey: "phoneIP") ?? "192.168.7.2"
        fastbootPath = d.string(forKey: "fastbootPath") ?? ""
        adbPath = d.string(forKey: "adbPath") ?? ""
        ghPath = d.string(forKey: "ghPath") ?? ""
        pythonPath = d.string(forKey: "pythonPath") ?? ""
        sshPath = d.string(forKey: "sshPath") ?? ""
        ghRepo = d.string(forKey: "ghRepo") ?? "ry-diffusion/ios-beryllium"
        rebootFromRecovery = d.bool(forKey: "rebootFromRecovery")
        notifyOnBoot = d.object(forKey: "notifyOnBoot") as? Bool ?? true
        allowRemoteStart = d.object(forKey: "allowRemoteStart") as? Bool ?? true
        autoSaveLog = d.object(forKey: "autoSaveLog") as? Bool ?? true
        notifyOnIOS = d.object(forKey: "notifyOnIOS") as? Bool ?? true
        preferBergamotaFastboot = d.object(forKey: "preferBergamotaFastboot") as? Bool ?? true
        bergamotaImagePath = d.string(forKey: "bergamotaImagePath") ?? Self.defaultBergamotaImage
        autoRebootToFastboot = d.object(forKey: "autoRebootToFastboot") as? Bool ?? true
    }

    var repoURL: URL { URL(fileURLWithPath: (repoPath as NSString).expandingTildeInPath) }
    func repoFile(_ rel: String) -> String { repoURL.appendingPathComponent(rel).path }
    var repoValid: Bool { FileManager.default.fileExists(atPath: repoFile("tools/mkpayload.py")) }

    var fastboot: String? { Shell.resolve("fastboot", override: fastbootPath) }
    var adb: String? { Shell.resolve("adb", override: adbPath) }
    var gh: String? { Shell.resolve("gh", override: ghPath) }
    var python: String? { Shell.resolve("python3", override: pythonPath) }
    var ssh: String? { Shell.resolve("ssh", override: sshPath) }
}
