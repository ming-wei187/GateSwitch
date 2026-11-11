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
        refresh(silent: true)
        helperReady = Self.isHelperReady()
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
        services = Self.listServices()
        if let info = Self.interfaceInfo(service: service) {
            currentIP = info.ip
            currentMask = info.mask
            currentRouter = info.router
            currentDNS = Self.dnsServers(service: service)
            isOn = info.router == onGateway
            if !silent {
                errorMessage = nil
            }
        }
        helperReady = Self.isHelperReady()
        launchAtLogin = FileManager.default.fileExists(atPath: Self.launchAgentURL.path)
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
        let target = on ? onGateway : offGateway
        apply(router: target)
    }

    func apply(router: String) {
        persist()
        guard Self.isIPv4(router), Self.isIPv4(onGateway), Self.isIPv4(offGateway) else {
            errorMessage = "请先在设置里填好两个合法的网关地址"
            showSettings = true
            return
        }
        refresh(silent: true)
        let ip = currentIP
        let mask = currentMask.isEmpty ? "255.255.255.0" : currentMask
        guard Self.isIPv4(ip), Self.isIPv4(mask) else {
            errorMessage = "读不到当前 IP，请先确认 \(service) 已连上网"
            return
        }

        busy = true
        errorMessage = nil
        statusMessage = "正在切换网关…"
        let serviceName = service
        let shouldSyncDNS = syncDNS
        let dns = shouldSyncDNS ? router : ""
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Never call networksetup directly from the app: macOS would ask
            // for the admin password on every toggle. After one helper install,
            // switches go through sudo -n and stay silent.
            let result: Result<Void, Error>
            if Self.isHelperReady() {
                result = Self.runHelper(service: serviceName, ip: ip, mask: mask, router: router, dns: dns)
            } else {
                result = Self.installHelperAndApply(
                    service: serviceName, ip: ip, mask: mask, router: router, dns: dns
                )
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                self.refresh(silent: true)
                switch result {
                case .success:
                    self.statusMessage = self.isOn ? "已切换到软路由" : "已切回主路由"
                    self.errorMessage = nil
                    if self.currentRouter != router {
                        self.errorMessage = "命令已执行，但当前网关还是 \(self.currentRouter.isEmpty ? "空的" : self.currentRouter)"
                        self.statusMessage = nil
                    }
                case .failure(let error):
                    self.statusMessage = nil
                    self.errorMessage = error.localizedDescription
                }
            }
        }
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
