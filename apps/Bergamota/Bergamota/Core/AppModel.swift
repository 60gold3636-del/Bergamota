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

    init() {
        let s = AppSettings()
        settings = s
        let m = PhoneMonitor(settings: s)
        monitor = m
        logs = LogStore(settings: s)
        ci = CIModel(settings: s)
        build = BuildModel(settings: s)
        queue = BootQueue(settings: s, monitor: m)
    }

    func start() {
        build.rescan()
        monitor.start()
        logs.start()
    }
}
