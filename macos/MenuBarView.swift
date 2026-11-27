import SwiftUI
import AppKit

enum PanelPage: String, CaseIterable, Identifiable {
    case connections = "当前连接"
    case rules = "分流规则"
    var id: String { rawValue }
}

struct MenuBarContentView: View {
    @ObservedObject var store: NetPilotStore
    let onResize: (CGFloat, CGFloat) -> Void
    let onPinChange: (Bool) -> Void
    var onLayoutChange: ((Bool, Bool, Bool) -> Void)? = nil

    @State private var page: PanelPage = .connections
    @State private var listExpanded = false
    @State private var hotspotExpanded = false

    @State private var hsInterface = ""
    @State private var hsSSIDs = ""
    @State private var hsProxyHost = ""
    @State private var hsProxyPort = 7890
    @State private var hsProxyType = "http"
    @State private var detectingWiFi = false

    @State private var pattern = ""
    @State private var phoneRule = true
    @State private var addingRule = false
    @State private var editingProviders = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 顶部标题栏
            HStack(spacing: 6) {
                Text("NetPilot").font(.title3.bold())
                Text("v0.0.1")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                let active = store.runtime?.hotspot.active ?? false
                Text(active ? "P · 分流中" : "D · 直连")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(active ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.08)))
                    .foregroundStyle(active ? Color.accentColor : Color.secondary)
                Spacer()
                Button { store.isPinned.toggle(); onPinChange(store.isPinned) } label: {
                    Image(systemName: store.isPinned ? "pin.fill" : "pin")
                        .foregroundStyle(store.isPinned ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .help("固定面板")
                Button("退出") { NSApp.terminate(nil) }
                    .controlSize(.small)
            }

            if let cfg = store.config {
                // 核心控制卡片：自动分流开关 + 开机自启开关 + 内联展开热点设置
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("自动分流")
                                .font(.subheadline.weight(.semibold))
                            Text(store.runtime?.hotspot.reason ?? "等待本地代理启动")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { cfg.hotspot.mode != "off" },
                            set: { enabled in
                                var h = cfg.hotspot
                                h.mode = enabled ? "auto" : "off"
                                store.save(h, key: "hotspot")
                            }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                    }

                    Divider().opacity(0.4)

                    HStack {
                        Text("开机自启")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        Toggle("", isOn: Binding(
                            get: { store.launchAtLogin },
                            set: { store.setLaunchAtLogin($0) }
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()

                        Spacer()

                        Button {
                            if !hotspotExpanded {
                                syncHotspotDraft(cfg.hotspot)
                            }
                            hotspotExpanded.toggle()
                            onLayoutChange?(listExpanded, hotspotExpanded, !store.message.isEmpty)
                        } label: {
                            HStack(spacing: 4) {
                                Text("热点设置")
                                    .font(.caption.weight(.medium))
                                Image(systemName: hotspotExpanded ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 9.5, weight: .semibold))
                            }
                            .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }

                    // 内联展开的手机热点设置（不再弹出第二页）
                    if hotspotExpanded {
                        VStack(alignment: .leading, spacing: 7) {
                            Divider().opacity(0.4)
                            HStack(spacing: 6) {
                                Text("Wi-Fi 网卡").font(.caption).foregroundStyle(.secondary).frame(width: 66, alignment: .leading)
                                TextField("en0", text: $hsInterface).textFieldStyle(.roundedBorder).controlSize(.small)
                                Text("协议").font(.caption).foregroundStyle(.secondary)
                                Picker("", selection: $hsProxyType) {
                                    Text("HTTP").tag("http")
                                    Text("SOCKS5").tag("socks5")
                                }
                                .labelsHidden()
                                .controlSize(.small)
                                .frame(width: 82)
                            }
                            HStack(spacing: 6) {
                                Text("热点名称").font(.caption).foregroundStyle(.secondary).frame(width: 66, alignment: .leading)
                                TextField("留空则按下方网关 IPv4 匹配", text: $hsSSIDs).textFieldStyle(.roundedBorder).controlSize(.small)
                                Button {
                                    detectingWiFi = true
                                    store.detectCurrentWiFi(preferredInterface: hsInterface) { detected in
                                        detectingWiFi = false
                                        guard let d = detected else {
                                            store.showMessage("未检测到已连接的 Wi-Fi")
                                            return
                                        }
                                        hsInterface = d.interface
                                        if !d.ssid.isEmpty {
                                            hsSSIDs = d.ssid
                                        }
                                        if !d.gateway.isEmpty {
                                            hsProxyHost = d.gateway
                                        }
                                        if !d.ssid.isEmpty {
                                            store.showMessage("已识别 Wi-Fi：\(d.ssid)（\(d.interface)\(d.gateway.isEmpty ? "" : " · \(d.gateway)")）")
                                        } else if !d.gateway.isEmpty {
                                            store.showMessage("已识别网卡 \(d.interface) 网关 \(d.gateway)（留空热点名称即可按网关匹配）")
                                        } else {
                                            store.showMessage("已检测到 Wi-Fi 网卡 \(d.interface)，但当前未连接热点")
                                        }
                                    }
                                } label: {
                                    Label(detectingWiFi ? "识别中" : "识别 Wi-Fi", systemImage: "wifi")
                                }
                                .controlSize(.small)
                                .disabled(detectingWiFi)
                            }
                            HStack(spacing: 6) {
                                Text("网关/端口").font(.caption).foregroundStyle(.secondary).frame(width: 66, alignment: .leading)
                                TextField("留空自动取网关", text: $hsProxyHost).textFieldStyle(.roundedBorder).controlSize(.small)
                                TextField("7890", value: $hsProxyPort, format: .number.grouping(.never))
                                    .textFieldStyle(.roundedBorder)
                                    .controlSize(.small)
                                    .frame(width: 64)
                            }
                            HStack {
                                Button("复制 PAC") { store.copy("http://127.0.0.1:\(cfg.pac_port ?? 7900)/proxy.pac") }
                                    .controlSize(.mini)
                                Button("复制 HTTP") { store.copy("http://" + cfg.listen_addr) }
                                    .controlSize(.mini)
                                Spacer()
                                Button("保存") {
                                    let ssids = hsSSIDs.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                                    let h = HotspotSettings(
                                        mode: cfg.hotspot.mode == "off" ? "auto" : cfg.hotspot.mode,
                                        interface: hsInterface.trimmingCharacters(in: .whitespaces),
                                        ssids: ssids,
                                        proxy_type: hsProxyType,
                                        proxy_port: hsProxyPort,
                                        proxy_host: hsProxyHost.trimmingCharacters(in: .whitespaces)
                                    )
                                    store.save(h, key: "hotspot")
                                    hotspotExpanded = false
                                    onLayoutChange?(listExpanded, hotspotExpanded, !store.message.isEmpty)
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                .disabled(hsInterface.trimmingCharacters(in: .whitespaces).isEmpty || !(1...65535).contains(hsProxyPort))
                            }
                        }
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))

                // 下方列表展开/收起开关栏 + 2 页切换（收起与展开高度与箭头位置完全锁定对齐，避免抖动）
                HStack(spacing: 8) {
                    if listExpanded {
                        Picker("", selection: $page) {
                            ForEach(PanelPage.allCases) { p in
                                Text(p.rawValue).tag(p)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(maxWidth: 200)
                        Spacer(minLength: 0)
                    } else {
                        let phoneCount = (store.runtime?.connections ?? []).filter { $0.egress == "phone" }.reduce(0) { $0 + $1.count }
                        Button {
                            listExpanded = true
                            onLayoutChange?(listExpanded, hotspotExpanded, !store.message.isEmpty)
                        } label: {
                            HStack {
                                Text("热点活跃 \(phoneCount) 连接 · \(cfg.domains.count) 条规则")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer(minLength: 0)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    Button {
                        listExpanded.toggle()
                        onLayoutChange?(listExpanded, hotspotExpanded, !store.message.isEmpty)
                    } label: {
                        Image(systemName: listExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 26, height: 22)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(listExpanded ? Color.primary.opacity(0.06) : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(listExpanded ? "收起列表" : "展开连接与规则列表")
                }
                .padding(.leading, listExpanded ? 0 : 10)
                .padding(.trailing, 2)
                .frame(height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(listExpanded ? Color.clear : Color.primary.opacity(0.05))
                )

                if listExpanded {
                    if page == .connections {
                        connectionsPage
                    } else {
                        rulesPage(cfg: cfg)
                    }
                }
            }

            if !store.message.isEmpty {
                Text(store.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            addingRule = false
            onLayoutChange?(listExpanded, hotspotExpanded, !store.message.isEmpty)
        }
        .onChange(of: store.message) { _, newVal in
            onLayoutChange?(listExpanded, hotspotExpanded, !newVal.isEmpty)
        }
    }

    private func syncHotspotDraft(_ h: HotspotSettings) {
        hsInterface = h.interface
        hsSSIDs = h.ssids.joined(separator: ",")
        hsProxyHost = h.proxy_host
        hsProxyPort = h.proxy_port
        hsProxyType = h.proxy_type
    }

    // MARK: - 第 1 页：仅显示当前走手机热点代理的活跃连接
    private var connectionsPage: some View {
        let phoneList = (store.runtime?.connections ?? []).filter { $0.egress == "phone" }
        let totalConns = phoneList.reduce(0) { $0 + $1.count }

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("当前走手机热点代理：\(phoneList.count) 个目标 · \(totalConns) 条连接")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(phoneList.isEmpty ? Color.secondary : Color.accentColor)
                Spacer()
            }
            .padding(.horizontal, 2)

            if phoneList.isEmpty {
                Spacer()
                Text("当前暂无走手机热点代理的活跃连接")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
            } else {
                List(phoneList) { item in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(item.host)
                                    .font(.system(.callout, design: .monospaced))
                                    .lineLimit(1)
                                Text("\(item.count)")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(Color.primary.opacity(0.07)))
                            }
                            if !item.rule.isEmpty {
                                Text("命中: \(item.rule)")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        Spacer()
                        Text("热点")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
        }
    }

    // MARK: - 第 2 页：分流规则
    private func rulesPage(cfg: Settings) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("未匹配走系统直连，直连规则优先")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(addingRule ? "取消" : "+ 添加") {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        addingRule.toggle()
                        if !addingRule { pattern = "" }
                    }
                }
                .controlSize(.small)

                Button("订阅规则集 (\(cfg.rule_providers?.count ?? 0))") { editingProviders = true }
                    .controlSize(.small)
                    .popover(isPresented: $editingProviders) { ProviderEditor(store: store) }
            }

            if addingRule {
                HStack(spacing: 6) {
                    TextField("域名、*.example.com 或 IP 网段", text: $pattern)
                        .textFieldStyle(.roundedBorder)
                    Picker("", selection: $phoneRule) {
                        Text("热点").tag(true)
                        Text("直连").tag(false)
                    }
                    .labelsHidden()
                    .frame(width: 68)
                    Button("保存") {
                        let p = pattern.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                        guard !p.isEmpty else { return }
                        var rules = cfg.domains.filter { $0.pattern.lowercased() != p }
                        rules.insert(DomainRule(id: UUID().uuidString, pattern: p, hotspot: phoneRule), at: 0)
                        store.save(rules, key: "domains")
                        pattern = ""
                        addingRule = false
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            List(cfg.domains) { rule in
                HStack {
                    Text(rule.pattern)
                        .font(.system(.callout, design: .monospaced))
                    Spacer()
                    Button(rule.hotspot ? "热点" : "直连") {
                        var rules = cfg.domains
                        if let i = rules.firstIndex(where: { $0.id == rule.id }) {
                            rules[i].hotspot.toggle()
                            store.save(rules, key: "domains")
                        }
                    }
                    .controlSize(.small)
                    Button {
                        store.save(cfg.domains.filter { $0.id != rule.id }, key: "domains")
                    } label: {
                        Image(systemName: "minus.circle")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct ProviderEditor: View {
    @ObservedObject var store: NetPilotStore
    @State private var name = ""
    @State private var url = ""
    @State private var behavior = "domain"
    @State private var format = "yaml"

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedURL: String { url.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var effectiveName: String {
        if !trimmedName.isEmpty { return trimmedName }
        guard let u = URL(string: trimmedURL) else { return "" }
        let stem = u.deletingPathExtension().lastPathComponent
        let cleaned = stem.replacingOccurrences(of: "[^a-zA-Z0-9_-]", with: "-", options: .regularExpression)
        return String(cleaned.prefix(80))
    }

    private var validationError: String? {
        if trimmedURL.isEmpty { return "请输入 HTTPS 规则集链接" }
        guard let parsed = URL(string: trimmedURL), parsed.scheme?.lowercased() == "https", parsed.host != nil else {
            return "链接必须以 https:// 开头"
        }
        let n = effectiveName
        if n.isEmpty { return "请填写英文、数字或连字符组成的名称" }
        if n.range(of: "^[a-zA-Z0-9_-]{1,80}$", options: .regularExpression) == nil {
            return "名称仅支持英文字母、数字、下划线或连字符（不支持中文和空格）"
        }
        if format == "mrs" && behavior == "classical" {
            return "mrs 格式不支持 classical 类型，请切换为 domain 或 ipcidr"
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("订阅规则集").font(.headline)
            Text("填写单个服务的 Mihomo 规则集链接。命中后走热点；公司直连规则优先。").font(.caption).foregroundStyle(.secondary)
            TextField("名称（英文/数字，留空自动从链接生成）", text: $name)
                .textFieldStyle(.roundedBorder)
            TextField("HTTPS 规则集地址（支持 .yaml / .mrs / .txt）", text: $url)
                .textFieldStyle(.roundedBorder)
                .onChange(of: url) { _, newVal in
                    let lower = newVal.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    if lower.hasSuffix(".mrs") {
                        format = "mrs"
                        if behavior == "classical" { behavior = "domain" }
                    } else if lower.hasSuffix(".yaml") || lower.hasSuffix(".yml") {
                        format = "yaml"
                    } else if lower.hasSuffix(".txt") || lower.hasSuffix(".list") {
                        format = "text"
                    }
                }
            HStack {
                Picker("类型", selection: $behavior) { ForEach(["domain", "ipcidr", "classical"], id: \.self) { Text($0) } }
                Picker("格式", selection: $format) { ForEach(["yaml", "text", "mrs"], id: \.self) { Text($0) } }
            }
            if let err = validationError, !trimmedURL.isEmpty || !trimmedName.isEmpty {
                Text(err).font(.caption).foregroundStyle(.orange)
            }
            Button("保存订阅") {
                let finalName = effectiveName
                let finalURL = trimmedURL
                var list = (store.config?.rule_providers ?? []).filter { $0.name != finalName }
                list.append(RuleProvider(name: finalName, url: finalURL, behavior: behavior, format: format))
                store.save(list, key: "rule_providers")
                name = ""
                url = ""
            }
            .buttonStyle(.borderedProminent)
            .disabled(validationError != nil)

            if let providers = store.config?.rule_providers, !providers.isEmpty {
                Divider()
                ForEach(providers) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.name).font(.callout.weight(.medium))
                            Text("\(item.behavior)/\(item.format)").font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("移除") {
                            store.save((store.config?.rule_providers ?? []).filter { $0.name != item.name }, key: "rule_providers")
                        }
                    }
                }
            }
        }
        .padding()
        .frame(width: 400)
    }
}
