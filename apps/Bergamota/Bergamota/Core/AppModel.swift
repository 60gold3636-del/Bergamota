import Foundation
import Observation

@Observable
@MainActor
final class AppModel {
    let settings: AppSettings
    let monitor: PhoneMonitor
    let logs: LogStore
    let ci: CIModel
    let build: BuildModel
    let queue: BootQueue
    let remote: RemoteControl

    init() {
        let s = AppSettings()
        settings = s
        let m = PhoneMonitor(settings: s)
        monitor = m
        logs = LogStore(settings: s)
        ci = CIModel(settings: s)
        build = BuildModel(settings: s)
        let q = BootQueue(settings: s, monitor: m)
        queue = q
        remote = RemoteControl(settings: s, monitor: m, queue: q, build: build, logs: logs)
    }

    func start() {
        build.rescan()
        monitor.start()
        logs.start()
        remote.start()
    }
}
