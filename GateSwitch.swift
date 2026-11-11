import SwiftUI
import AppKit
import Foundation

@main
struct GateSwitchApp: App {
    @StateObject private var model = GatewayModel()

    var body: some Scene {
        MenuBarExtra {
            RootView()
                .environmentObject(model)
                .frame(width: 300)
        } label: {
            Image(nsImage: GatewayMenuIcon.image(isOn: model.isOn))
                .help(model.isOn ? "网关：软路由" : "网关：主路由")
        }
        .menuBarExtraStyle(.window)
    }
}

final class GatewayModel: ObservableObject {
    static let helperPath = "/usr/local/libexec/soft-router-toggle"
    static let sudoersPath = "/etc/sudoers.d/soft-router-toggle"
    static let legacySuite = "com.ming.SoftRouterToggle"
    static let defaultOnGateway = ""
    static let defaultOffGateway = ""
    static let defaultService = "Wi-Fi"

    @Published var isOn = false
    @Published var currentRouter = ""
    @Published var currentIP = ""
    @Published var currentMask = ""
    @Published var currentDNS = ""
    @Published var service: String
    @Published var onGateway: String
    @Published var offGateway: String
    @Published var syncDNS: Bool
    @Published var launchAtLogin: Bool
    @Published var helperReady = false
    @Published var busy = false
    @Published var statusMessage: String?
    @Published var errorMessage: String?
    @Published var showSettings = false
    @Published var services: [String] = []

    private var refreshTimer: Timer?
    // Invalidates a status poll that started before a toggle, so it cannot
    // write the old gateway back over the knob while it is sliding.
    private var epoch = 0
    private var refreshInFlight = false
    private var applyInFlight = false
    private var applyToken = 0
    private static let workQueue = DispatchQueue(label: "com.ming.GateSwitch.network", qos: .userInitiated)
    /// Hold popover layout changes until the knob has finished sliding.
    private static let switchAnimationDuration: TimeInterval = 0.35

    init() {
        Self.migrateDefaultsIfNeeded()
        let d = UserDefaults.standard
        service = d.string(forKey: "service") ?? Self.defaultService
        onGateway = d.string(forKey: "onGateway") ?? Self.defaultOnGateway
        offGateway = d.string(forKey: "offGateway") ?? Self.defaultOffGateway
        if d.object(forKey: "syncDNS") == nil {
            syncDNS = true
        } else {
            syncDNS = d.bool(forKey: "syncDNS")
        }
        Self.migrateLaunchAgentIfNeeded()
        launchAtLogin = FileManager.default.fileExists(atPath: Self.launchAgentURL.path)
        publish(Self.readSnapshot(service: service), silent: true, updateSwitch: true)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.refresh(silent: true)
        }
        if let timer = refreshTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func persist() {
        let d = UserDefaults.standard
        d.set(service, forKey: "service")
        d.set(onGateway, forKey: "onGateway")
        d.set(offGateway, forKey: "offGateway")
        d.set(syncDNS, forKey: "syncDNS")
    }

    func refresh(silent: Bool = false) {
        // The timer runs in .common, including while the switch is tracking.
        // networksetup / sudo must stay off the main thread or the knob freezes.
        if applyInFlight || refreshInFlight { return }
        refreshInFlight = true
        let started = epoch
        let serviceName = service
        Self.workQueue.async { [weak self] in
            let snapshot = Self.readSnapshot(service: serviceName)
            DispatchQueue.main.async {
                guard let self else { return }
                self.refreshInFlight = false
                guard !self.applyInFlight, self.epoch == started else { return }
                self.publish(snapshot, silent: silent, updateSwitch: true)
            }
        }
    }

    var statusText: String {
        if currentRouter == onGateway {
            return "已连接到软路由"
        }
        if currentRouter == offGateway {
            return "已直连主路由"
        }
        if currentRouter.isEmpty {
            return "还没读到当前网关"
        }
        return "当前网关与设置不一致"
    }

    func setOn(_ on: Bool) {
        apply(router: on ? onGateway : offGateway)
    }

    func apply(router: String) {
        persist()
        guard Self.isIPv4(router), Self.isIPv4(onGateway), Self.isIPv4(offGateway) else {
            errorMessage = "请先在设置里填好两个合法的网关地址"
            showSettings = true
            return
        }
        // Ignore a second click until this one finishes. isOn stays where the
        // knob already is, so the switch does not bounce back and forth.
        if applyInFlight {
            return
        }

        let previousOn = isOn
        // Move the knob now, before any process waits. busy / status stay put
        // until the slide finishes: a progress row resizes the popover and
        // cuts the animation off.
        isOn = (router == onGateway)
        epoch += 1
        applyInFlight = true
        applyToken += 1
        let token = applyToken
        let serviceName = service
        let dns = syncDNS ? router : ""
        let requestedAt = Date()

        Self.workQueue.async { [weak self] in
            let outcome = Self.performNetworkChange(service: serviceName, router: router, dns: dns)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let remaining = Self.switchAnimationDuration - Date().timeIntervalSince(requestedAt)
                DispatchQueue.main.asyncAfter(deadline: .now() + max(0.0, remaining)) { [weak self] in
                    self?.finishApply(outcome, router: router, previousOn: previousOn, token: token)
                }
            }
        }

        // Just after a fast result lands, so the progress row does not flash in
        // and resize the popover at the end of the slide.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.switchAnimationDuration + 0.05) { [weak self] in
            guard let self, self.applyToken == token, self.applyInFlight else { return }
            self.busy = true
            self.errorMessage = nil
            self.statusMessage = "正在切换网关…"
        }
    }

    private func finishApply(_ outcome: NetworkOutcome, router: String, previousOn: Bool, token: Int) {
        guard applyToken == token else { return }
        let snapshot = outcome.snapshot
        epoch += 1
        applyInFlight = false
        busy = false
        switch outcome.result {
        case .success:
            publish(snapshot, silent: true, updateSwitch: false)
            if snapshot.hasInterface {
                let resolvedOn = snapshot.router == onGateway
                if isOn != resolvedOn {
                    isOn = resolvedOn
                }
            }
            if snapshot.hasInterface, snapshot.router != router {
                errorMessage = "命令已执行，但当前网关还是 \(snapshot.router.isEmpty ? "空的" : snapshot.router)"
                statusMessage = nil
            } else {
                statusMessage = isOn ? "已切换到软路由" : "已切回主路由"
                errorMessage = nil
            }
        case .failure(let error):
            publish(snapshot, silent: true, updateSwitch: false)
            if isOn != previousOn {
                isOn = previousOn
            }
            statusMessage = nil
            errorMessage = error.localizedDescription
        }
    }

    private func publish(_ snapshot: InterfaceSnapshot, silent: Bool, updateSwitch: Bool) {
        services = snapshot.services
        if snapshot.hasInterface {
            currentIP = snapshot.ip
            currentMask = snapshot.mask
            currentRouter = snapshot.router
            currentDNS = snapshot.dns
            if updateSwitch {
                isOn = snapshot.router == onGateway
            }
            if !silent {
                errorMessage = nil
            }
        }
        helperReady = snapshot.helperReady
        launchAtLogin = snapshot.launchAtLogin
    }

    private struct InterfaceSnapshot {
        var services: [String] = []
        var ip = ""
        var mask = ""
        var router = ""
        var dns = ""
        var helperReady = false
        var launchAtLogin = false
        var hasInterface = false
    }

    private struct NetworkOutcome {
        var result: Result<Void, Error>
        var snapshot: InterfaceSnapshot
    }

    private static func readSnapshot(service: String) -> InterfaceSnapshot {
        let info = interfaceInfo(service: service)
        return InterfaceSnapshot(
            services: listServices(),
            ip: info?.ip ?? "",
            mask: info?.mask ?? "",
            router: info?.router ?? "",
            dns: dnsServers(service: service),
            helperReady: isHelperReady(),
            launchAtLogin: FileManager.default.fileExists(atPath: launchAgentURL.path),
            hasInterface: info != nil
        )
    }

    private static func performNetworkChange(service: String, router: String, dns: String) -> NetworkOutcome {
        // Never call networksetup directly from the app: macOS would ask
        // for the admin password on every toggle. After one helper install,
        // switches go through sudo -n and stay silent.
        guard let info = interfaceInfo(service: service) else {
            return NetworkOutcome(
                result: .failure(SimpleError("读不到当前 IP，请先确认 \(service) 已连上网")),
                snapshot: readSnapshot(service: service)
            )
        }
        let ip = info.ip
        let mask = info.mask.isEmpty ? "255.255.255.0" : info.mask
        guard isIPv4(ip), isIPv4(mask) else {
            return NetworkOutcome(
                result: .failure(SimpleError("读不到当前 IP，请先确认 \(service) 已连上网")),
                snapshot: readSnapshot(service: service)
            )
        }
        let result: Result<Void, Error>
        if isHelperReady() {
            result = runHelper(service: service, ip: ip, mask: mask, router: router, dns: dns)
        } else {
            result = installHelperAndApply(
                service: service, ip: ip, mask: mask, router: router, dns: dns
            )
        }
        return NetworkOutcome(result: result, snapshot: readSnapshot(service: service))
    }

    static var launchAgentURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/LaunchAgents/com.ming.GateSwitch.plist")
    }

    static var legacyLaunchAgentURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/LaunchAgents/com.ming.SoftRouterToggle.plist")
    }

    static func migrateDefaultsIfNeeded() {
        let d = UserDefaults.standard
        if d.object(forKey: "onGateway") != nil || d.object(forKey: "offGateway") != nil {
            return
        }
        guard let old = UserDefaults(suiteName: legacySuite) else { return }
        if let value = old.string(forKey: "service") { d.set(value, forKey: "service") }
        if let value = old.string(forKey: "onGateway") { d.set(value, forKey: "onGateway") }
        if let value = old.string(forKey: "offGateway") { d.set(value, forKey: "offGateway") }
        if old.object(forKey: "syncDNS") != nil {
            d.set(old.bool(forKey: "syncDNS"), forKey: "syncDNS")
        }
    }

    static func migrateLaunchAgentIfNeeded() {
        let fm = FileManager.default
        let newURL = launchAgentURL
        let oldURL = legacyLaunchAgentURL
        guard fm.fileExists(atPath: oldURL.path) else { return }
        let plist: [String: Any] = [
            "Label": "com.ming.GateSwitch",
            "ProgramArguments": ["/usr/bin/open", "-j", "-a", Bundle.main.bundlePath],
            "RunAtLoad": true,
            "LimitLoadToSessionType": "Aqua"
        ]
        do {
            try fm.createDirectory(at: newURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: newURL, options: .atomic)
            try fm.removeItem(at: oldURL)
        } catch {
            // Keep the previous launch agent if the rewrite fails.
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        let url = Self.launchAgentURL
        do {
            if enabled {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let plist: [String: Any] = [
                    "Label": "com.ming.GateSwitch",
                    "ProgramArguments": ["/usr/bin/open", "-j", "-a", Bundle.main.bundlePath],
                    "RunAtLoad": true,
                    "LimitLoadToSessionType": "Aqua"
                ]
                let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                try data.write(to: url, options: .atomic)
                if FileManager.default.fileExists(atPath: Self.legacyLaunchAgentURL.path) {
                    try FileManager.default.removeItem(at: Self.legacyLaunchAgentURL)
                }
            } else {
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
                if FileManager.default.fileExists(atPath: Self.legacyLaunchAgentURL.path) {
                    try FileManager.default.removeItem(at: Self.legacyLaunchAgentURL)
                }
            }
            launchAtLogin = FileManager.default.fileExists(atPath: url.path)
            errorMessage = nil
        } catch {
            errorMessage = "开机启动设置失败：\(error.localizedDescription)"
            launchAtLogin = FileManager.default.fileExists(atPath: url.path)
        }
    }

    static func isHelperReady() -> Bool {
        guard let bundled = Bundle.main.path(forResource: "soft-router-toggle", ofType: nil),
              FileManager.default.fileExists(atPath: helperPath) else {
            return false
        }
        guard let installedData = try? Data(contentsOf: URL(fileURLWithPath: helperPath)),
              let bundledData = try? Data(contentsOf: URL(fileURLWithPath: bundled)),
              installedData == bundledData else {
            return false
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        task.arguments = ["-n", helperPath, "--ping"]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }

    static func runHelper(service: String, ip: String, mask: String, router: String, dns: String) -> Result<Void, Error> {
        var args = ["-n", helperPath, "--service", service, "--ip", ip, "--mask", mask, "--router", router]
        if !dns.isEmpty {
            args += ["--dns", dns]
        }
        return run("/usr/bin/sudo", args)
    }

    static func installHelperAndApply(service: String, ip: String, mask: String, router: String, dns: String) -> Result<Void, Error> {
        guard let helperSource = Bundle.main.path(forResource: "soft-router-toggle", ofType: nil) else {
            return .failure(SimpleError("找不到内置的权限组件"))
        }
        let user = NSUserName()
        guard user.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil else {
            return .failure(SimpleError("用户名无法用于安装权限组件"))
        }

        let script = """
        set -euo pipefail
        /bin/mkdir -p /usr/local/libexec
        /bin/cp \(shQuote(helperSource)) \(shQuote(helperPath))
        /usr/sbin/chown root:wheel \(shQuote(helperPath))
        /bin/chmod 755 \(shQuote(helperPath))
        /bin/cat > \(shQuote(sudoersPath)) << 'SUDOERS'
        \(user) ALL=(root) NOPASSWD: \(helperPath)
        SUDOERS
        /bin/chmod 440 \(shQuote(sudoersPath))
        /usr/sbin/visudo -cf \(shQuote(sudoersPath))
        \(shQuote(helperPath)) --service \(shQuote(service)) --ip \(shQuote(ip)) --mask \(shQuote(mask)) --router \(shQuote(router))\(dns.isEmpty ? "" : " --dns \(shQuote(dns))")
        """

        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("soft-router-toggle-install.sh")
        do {
            try script.write(to: tmp, atomically: true, encoding: .utf8)
        } catch {
            return .failure(SimpleError("写安装脚本失败：\(error.localizedDescription)"))
        }

        let apple = "do shell script \(asQuote("/bin/bash \(shQuote(tmp.path))")) with administrator privileges"
        let result = run("/usr/bin/osascript", ["-e", apple])
        try? FileManager.default.removeItem(at: tmp)
        return result
    }

    static func run(_ launchPath: String, _ arguments: [String]) -> Result<Void, Error> {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: launchPath)
        task.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        task.standardOutput = out
        task.standardError = err
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return .failure(error)
        }
        if task.terminationStatus == 0 {
            return .success(())
        }
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        var message = String(data: errData, encoding: .utf8) ?? ""
        if message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            message = String(data: outData, encoding: .utf8) ?? ""
        }
        message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if message.isEmpty {
            message = "命令失败，退出码 \(task.terminationStatus)"
        }
        if message.lowercased().contains("user canceled") || message.lowercased().contains("user cancelled") || message.contains("-128") {
            return .failure(SimpleError("已取消，没有改网关"))
        }
        return .failure(SimpleError(message))
    }

    static func listServices() -> [String] {
        let output = shell("/usr/sbin/networksetup", ["-listallnetworkservices"])
        return output
            .split(separator: "\n")
            .map { String($0) }
            .filter { !$0.hasPrefix("An asterisk") && !$0.hasPrefix("*") && !$0.isEmpty }
    }

    static func interfaceInfo(service: String) -> (ip: String, mask: String, router: String)? {
        let output = shell("/usr/sbin/networksetup", ["-getinfo", service])
        var ip = ""
        var mask = ""
        var router = ""
        for raw in output.split(separator: "\n") {
            let line = String(raw)
            if let value = field(line, prefix: "IP address:") {
                ip = value
            } else if let value = field(line, prefix: "Subnet mask:") {
                mask = value
            } else if let value = field(line, prefix: "Router:") {
                router = value
            }
        }
        if ip.isEmpty && mask.isEmpty && (router.isEmpty || router.lowercased() == "none") {
            return nil
        }
        if router.lowercased() == "none" {
            router = ""
        }
        return (ip, mask, router)
    }

    static func dnsServers(service: String) -> String {
        let output = shell("/usr/sbin/networksetup", ["-getdnsservers", service]).trimmingCharacters(in: .whitespacesAndNewlines)
        if output.lowercased().contains("aren't any dns") || output.isEmpty {
            return ""
        }
        return output.split(whereSeparator: \.isNewline).joined(separator: ", ")
    }

    static func field(_ line: String, prefix: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func shell(_ launchPath: String, _ arguments: [String]) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: launchPath)
        task.arguments = arguments
        let out = Pipe()
        task.standardOutput = out
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return ""
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func isIPv4(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        for part in parts {
            guard let n = Int(part), (0...255).contains(n), String(n) == String(part) else {
                return false
            }
        }
        return true
    }

    static func shQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    static func asQuote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

struct SimpleError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}


enum GatewayMenuIcon {
    static func image(isOn: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let alpha: CGFloat = isOn ? 1.0 : 0.38
            NSColor.black.withAlphaComponent(alpha).setStroke()
            NSColor.black.withAlphaComponent(alpha).setFill()

            let inset = rect.insetBy(dx: 1.25, dy: 1.25)
            let midX = inset.midX
            let midY = inset.midY
            let diamondR: CGFloat = 3.1

            let line = NSBezierPath()
            line.lineWidth = 1.6
            line.lineCapStyle = .round
            line.lineJoinStyle = .round
            line.move(to: NSPoint(x: inset.minX, y: midY))
            line.line(to: NSPoint(x: midX - diamondR, y: midY))
            line.stroke()

            let diamond = NSBezierPath()
            diamond.lineWidth = 1.6
            diamond.lineCapStyle = .round
            diamond.lineJoinStyle = .round
            diamond.move(to: NSPoint(x: midX, y: midY - diamondR))
            diamond.line(to: NSPoint(x: midX + diamondR, y: midY))
            diamond.line(to: NSPoint(x: midX, y: midY + diamondR))
            diamond.line(to: NSPoint(x: midX - diamondR, y: midY))
            diamond.close()
            diamond.stroke()

            let outbound = NSBezierPath()
            outbound.lineWidth = 1.6
            outbound.lineCapStyle = .round
            outbound.lineJoinStyle = .round
            outbound.move(to: NSPoint(x: midX + diamondR, y: midY))
            outbound.line(to: NSPoint(x: inset.maxX, y: midY))
            outbound.stroke()

            let arrow = NSBezierPath()
            arrow.lineWidth = 1.6
            arrow.lineCapStyle = .round
            arrow.lineJoinStyle = .round
            let tipX = inset.maxX
            arrow.move(to: NSPoint(x: tipX - 3.3, y: midY - 2.6))
            arrow.line(to: NSPoint(x: tipX, y: midY))
            arrow.line(to: NSPoint(x: tipX - 3.3, y: midY + 2.6))
            arrow.stroke()

            return true
        }
        image.isTemplate = true
        return image
    }
}

struct RootView: View {
    @EnvironmentObject var model: GatewayModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("网关切换")
                    .font(.headline)
                Spacer()
                Button {
                    model.showSettings.toggle()
                } label: {
                    Image(systemName: "gearshape")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("设置")
            }

            Toggle(isOn: Binding(
                get: { model.isOn },
                set: { model.setOn($0) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.isOn ? "已开启" : "已关闭")
                        .font(.body.weight(.semibold))
                    Text(model.statusText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.large)
            .disabled(model.busy)

            VStack(alignment: .leading, spacing: 2) {
                infoRow("当前网关", model.currentRouter.isEmpty ? "—" : model.currentRouter)
                infoRow("本机 IP", model.currentIP.isEmpty ? "—" : model.currentIP)
                if !model.currentDNS.isEmpty {
                    infoRow("DNS", model.currentDNS)
                }
            }
            .font(.caption)
            .foregroundColor(.secondary)

            if model.busy {
                ProgressView(model.statusMessage ?? "正在切换…")
                    .controlSize(.small)
            } else if let error = model.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let status = model.statusMessage {
                Text(status)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if model.showSettings {
                Divider()
                SettingsView()
            }

            if !model.helperReady && !model.showSettings {
                Text("再输入一次管理员密码后，以后切换都不会再弹")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            Button {
                NSApp.terminate(nil)
            } label: {
                Text("退出")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .padding(.vertical, 1)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .onAppear { model.refresh(silent: true) }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .textSelection(.enabled)
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: GatewayModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("网卡", selection: $model.service) {
                ForEach(model.services, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            .onChange(of: model.service) { _ in
                model.persist()
                model.refresh(silent: true)
            }

            field("打开时（软路由）", text: $model.onGateway)
            field("关闭时（主路由）", text: $model.offGateway)

            Toggle("同时切换 DNS", isOn: $model.syncDNS)
                .onChange(of: model.syncDNS) { _ in model.persist() }

            Toggle("开机自动启动", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }
            ))

            Text("现在默认：打开 → \(model.onGateway)，关闭 → \(model.offGateway)。改完会自动保存。")
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: model.onGateway) { _ in model.persist() }
        .onChange(of: model.offGateway) { _ in model.persist() }
    }

    private func field(_ title: String, text: Binding<String>) -> some View {
        HStack {
            Text(title)
            TextField("例如 192.168.1.1", text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
        }
    }
}
