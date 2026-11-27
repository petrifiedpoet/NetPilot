import Foundation
import AppKit
import ServiceManagement

struct DomainRule: Codable, Identifiable, Equatable {
    var id: String
    var pattern: String
    var hotspot: Bool
    var note: String?
}
struct HotspotSettings: Codable, Equatable {
    var mode: String
    var interface: String
    var ssids: [String]
    var proxy_type: String
    var proxy_port: Int
    var proxy_host: String
}
struct RuleProvider: Codable, Identifiable, Equatable {
    var name: String
    var url: String
    var behavior: String
    var format: String
    var id: String { name }
}
struct Settings: Decodable, Equatable {
    var pac_port: Int?
    var rule_providers: [RuleProvider]?
    var listen_addr: String
    var hotspot: HotspotSettings
    var domains: [DomainRule]
}
struct HotspotRuntime: Decodable, Equatable {
    var active: Bool
    var reason: String
}
struct LiveConnection: Decodable, Identifiable, Equatable {
    var id: String
    var host: String
    var egress: String // "phone" | "direct"
    var rule: String
    var count: Int
}
struct RuntimeSnapshot: Decodable, Equatable {
    var pid: Int
    var hotspot: HotspotRuntime
    var connections: [LiveConnection]?
}

struct DetectedWiFi {
    var interface: String
    var ssid: String
    var gateway: String
}

@MainActor
final class NetPilotStore: ObservableObject {
    @Published var config: Settings?
    @Published var runtime: RuntimeSnapshot?
    @Published var message = ""
    @Published var isPinned = false
    @Published var launchAtLogin = false
    private let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/netpilot")
    private var daemon: Process?
    private var timer: Timer?
    private var clearMessageTask: Task<Void, Never>?
    private var lastConfigMtime: Date?
    var configURL: URL { directory.appendingPathComponent("config.json") }

    init() {
        let p = Process()
        p.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/netpilot-core")
        p.arguments = ["daemon", "--config", configURL.path]
        do { try p.run(); daemon = p } catch { message = error.localizedDescription }
        refreshLaunchAtLogin()
        reloadAll(forceConfig: true)
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reloadAll(forceConfig: false) }
        }
    }

    func refreshLaunchAtLogin() {
        if SMAppService.mainApp.status == .enabled {
            launchAtLogin = true
            return
        }
        Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", "tell application \"System Events\" to get the name of every login item"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let enabled = out.contains("NetPilot")
            await MainActor.run {
                self.launchAtLogin = enabled || (SMAppService.mainApp.status == .enabled)
            }
        }
    }

    func showMessage(_ text: String, autoClear: Bool = true) {
        clearMessageTask?.cancel()
        message = text
        guard autoClear, !text.isEmpty else { return }
        clearMessageTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                if self?.message == text {
                    self?.message = ""
                }
            }
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLogin = enabled
        Task.detached {
            if enabled {
                do {
                    try SMAppService.mainApp.register()
                } catch {
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                    p.arguments = ["-e", "tell application \"System Events\" to if not (exists login item \"NetPilot\") then make login item at end with properties {path:\"/Applications/NetPilot.app\", hidden:false}"]
                    try? p.run()
                    p.waitUntilExit()
                }
                await MainActor.run { self.showMessage("已开启开机自启") }
            } else {
                try? await SMAppService.mainApp.unregister()
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                p.arguments = ["-e", "tell application \"System Events\" to if exists login item \"NetPilot\" then delete login item \"NetPilot\""]
                try? p.run()
                p.waitUntilExit()
                await MainActor.run { self.showMessage("已关闭开机自启") }
            }
        }
    }
    func stop() {
        timer?.invalidate()
        clearMessageTask?.cancel()
        if let daemon, daemon.isRunning { daemon.terminate() }
    }
    func reloadAll(forceConfig: Bool) {
        let decoder = JSONDecoder()
        let cfgMtime = (try? FileManager.default.attributesOfItem(atPath: configURL.path))?[.modificationDate] as? Date
        if forceConfig || cfgMtime != lastConfigMtime {
            if let data = try? Data(contentsOf: configURL) {
                do {
                    let decoded = try decoder.decode(Settings.self, from: data)
                    lastConfigMtime = cfgMtime
                    if decoded != config {
                        config = decoded
                    }
                } catch {
                    showMessage("配置读取失败 · " + error.localizedDescription, autoClear: false)
                }
            }
        }
        let file = directory.appendingPathComponent("runtime.json")
        let nextRuntime: RuntimeSnapshot?
        if let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
           let date = attrs[.modificationDate] as? Date, Date().timeIntervalSince(date) < 15,
           let data = try? Data(contentsOf: file) {
            nextRuntime = try? decoder.decode(RuntimeSnapshot.self, from: data)
        } else {
            nextRuntime = nil
        }
        if nextRuntime != runtime {
            runtime = nextRuntime
        }
        if runtime == nil, let daemon, !daemon.isRunning {
            showMessage("核心未启动，请检查配置及代理端口是否由旧版占用", autoClear: false)
        }
    }
    func save<T: Encodable>(_ value: T, key: String) {
        do {
            guard var root = try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any]
            else { throw CocoaError(.fileReadCorruptFile) }
            root[key] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
            try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted,.sortedKeys]).write(to: configURL, options: .atomic)
            showMessage("已保存")
            reloadAll(forceConfig: true)
        } catch { showMessage(error.localizedDescription, autoClear: false) }
    }
    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showMessage("已复制 " + text)
    }

    func detectCurrentWiFi(preferredInterface: String, completion: @escaping (DetectedWiFi?) -> Void) {
        Task.detached {
            func run(_ path: String, _ args: [String]) -> String {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: path)
                p.arguments = args
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = FileHandle.nullDevice
                do {
                    try p.run()
                    p.waitUntilExit()
                    guard p.terminationStatus == 0 else { return "" }
                    return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                } catch {
                    return ""
                }
            }

            // 1. 查找 Wi-Fi 网卡名（默认回退到 preferredInterface 或 en0）
            var iface = preferredInterface.trimmingCharacters(in: .whitespacesAndNewlines)
            let ports = run("/usr/sbin/networksetup", ["-listallhardwareports"])
            let lines = ports.components(separatedBy: .newlines)
            for idx in lines.indices {
                let line = lines[idx]
                if line.contains("Hardware Port: Wi-Fi") || line.contains("Hardware Port: AirPort") {
                    if idx + 1 < lines.count, lines[idx + 1].hasPrefix("Device: ") {
                        let dev = lines[idx + 1].replacingOccurrences(of: "Device: ", with: "").trimmingCharacters(in: .whitespaces)
                        if !dev.isEmpty {
                            iface = dev
                            break
                        }
                    }
                }
            }
            if iface.isEmpty { iface = "en0" }

            // 2. 读取当前 SSID 与网关 IP
            let summary = run("/usr/sbin/ipconfig", ["getsummary", iface])
            var ssid = ""
            for raw in summary.components(separatedBy: .newlines) {
                let trimmed = raw.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("SSID : ") {
                    let val = String(trimmed.dropFirst("SSID : ".count)).trimmingCharacters(in: .whitespaces)
                    if !val.isEmpty && val != "<redacted>" {
                        ssid = val
                    }
                    break
                }
            }
            let gateway = run("/usr/sbin/ipconfig", ["getoption", iface, "router"])
            let ip = run("/usr/sbin/ipconfig", ["getifaddr", iface])

            let result: DetectedWiFi? = (!ssid.isEmpty || !gateway.isEmpty || !ip.isEmpty)
                ? DetectedWiFi(interface: iface, ssid: ssid, gateway: gateway)
                : nil

            await MainActor.run {
                completion(result)
            }
        }
    }
}
