import SwiftUI

func formatUptime(_ t: TimeInterval) -> String {
    let s = Int(t), d = s / 86400, h = s % 86400 / 3600, m = s % 3600 / 60
    if d > 0 { return "\(d)d \(h)h \(m)m" }
    if h > 0 { return "\(h)h \(m)m" }
    return "\(m)m \(s % 60)s"
}

struct Card<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol).font(.headline)
            Divider()
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct Row: View {
    let k: String
    let v: String
    var ok: Bool? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            if let ok { Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle").foregroundStyle(ok ? .green : .secondary) }
            Text(v).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
        .font(.callout)
    }
}

struct DashboardView: View {
    @Environment(AppModel.self) private var model

    private var hint: String {
        switch model.monitor.state {
        case .unknown: "Probing the phone..."
        case .offline: "No device seen. Hold Power + Volume Down for fastboot, or plug the phone in."
        case .fastboot: "Phone is in fastboot (serial \(model.monitor.fastbootSerial ?? "?")). Ready for `fastboot boot`."
        case .recovery: "OrangeFox / recovery over adb (\(model.monitor.adbSerial ?? "?"))."
        case .android: "Android is up over adb (\(model.monitor.adbSerial ?? "?"))."
        case .iosBooting: "USB Ethernet is up but SSH is not answering yet."
        case .ios: "iOS is up: ping and SSH answer."
        }
    }

    var body: some View {
        let m = model.monitor
        ScrollView {
            VStack(spacing: 16) {
                HStack(spacing: 16) {
                    Image(systemName: m.state.symbol)
                        .font(.system(size: 40))
                        .foregroundStyle(stateColor(m.state))
                        .frame(width: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(m.state.title).font(.largeTitle.bold())
                        Text(hint).foregroundStyle(.secondary)
                        Text("in this state since \(m.stateSince.formatted(date: .omitted, time: .standard))")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    if let l = m.lastPoll { Text("polled \(l.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(.tertiary) }
                }
                .padding(18)
                .background(stateColor(m.state).opacity(0.12), in: RoundedRectangle(cornerRadius: 14))

                if !m.toolWarnings.isEmpty {
                    ForEach(m.toolWarnings, id: \.self) { w in
                        Label(w, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                Grid(horizontalSpacing: 16, verticalSpacing: 16) {
                    GridRow {
                        Card(title: "Detection", symbol: "dot.radiowaves.left.and.right") {
                            Row(k: "fastboot", v: m.fastbootSerial ?? "none", ok: m.fastbootSerial != nil)
                            Row(k: "adb", v: m.adbState.map { "\($0) (\(m.adbSerial ?? ""))" } ?? "none", ok: m.adbState != nil)
                            Row(k: "USB Ethernet", v: m.ifaceName.map { $0 + (m.ifaceUp ? " up" : " down") } ?? "not found", ok: m.ifaceUp)
                            Row(k: "ping \(model.settings.phoneIP)", v: m.pingOK ? "reply" : "no reply", ok: m.pingOK)
                            Row(k: "TCP 22", v: m.sshOpen ? "open" : "closed", ok: m.sshOpen)
                        }
                        Card(title: "Mac side", symbol: "laptopcomputer") {
                            Row(k: "IP forwarding", v: m.natForwarding.map { $0 == "1" ? "on (NAT shared)" : "off" } ?? "unknown",
                                ok: m.natForwarding == "1")
                            Row(k: "Phone MAC", v: PhoneMonitor.usbMAC)
                            Row(k: "Log listener", v: model.logs.listening ? "udp/5140" : (model.logs.listenError ?? "stopped"), ok: model.logs.listening)
                            Text("Enable NAT with tools/sweet-mac-nat.sh (needs sudo).").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                }

                Card(title: "iOS device", symbol: "iphone") {
                    if m.state != .ios {
                        Text("Available when iOS is up.").foregroundStyle(.secondary)
                    } else if let i = m.info {
                        HStack(spacing: 20) {
                            VStack(alignment: .leading) {
                                if let p = i.batteryPercent {
                                    Gauge(value: Double(p), in: 0...100) { Text("Battery") } currentValueLabel: { Text("\(p)%") }
                                        .gaugeStyle(.accessoryCircularCapacity).tint(p < 20 ? .red : .green).scaleEffect(1.4).frame(width: 70, height: 70)
                                } else { Text("Battery n/a").foregroundStyle(.secondary) }
                            }
                            VStack(spacing: 8) {
                                Row(k: "Charging", v: i.isCharging.map { $0 ? "yes" : "no" } ?? "unknown")
                                Row(k: "Power source", v: i.powerSource ?? "unknown")
                                Row(k: "Uptime", v: i.uptime.map(formatUptime) ?? "unknown")
                                Row(k: "Booted", v: i.bootDate?.formatted(date: .abbreviated, time: .standard) ?? "unknown")
                            }
                        }
                        Row(k: "Kernel", v: i.uname)
                    } else if let e = m.infoError {
                        Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled)
                    } else {
                        HStack { ProgressView().controlSize(.small); Text("Querying over SSH...") }
                    }
                    if m.state == .ios, m.info != nil, let e = m.infoError { Text(e).font(.caption).foregroundStyle(.orange) }
                    if m.state == .ios {
                        Button("Refresh now") { Task { await m.refreshInfoIfNeeded(force: true) } }.controlSize(.small)
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("Dashboard")
    }
}
