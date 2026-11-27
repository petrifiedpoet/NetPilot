# NetPilot

> 当前版本：**v0.0.1**

轻量级**按目的地分流**工具，专为「办公网 / 公司 VPN + 手机热点代理」双网卡场景设计：有线内网与公司 VPN 继续完全由系统路由管理，仅将指定目标域名、IP 网段或规则集流量经由手机热点上的 HTTP/SOCKS5 代理转发。

macOS 菜单栏应用与 Windows 命令行共用同一套 Rust 守护核心（`netpilot-core`）和 Mihomo v1.19.34。

## 核心特性

- **零侵入系统网络**：不启用 TUN 虚拟网卡，不修改公司 VPN、系统路由表或系统 DNS。
- **选择性平滑回退**：检测到手机热点断开或手动关闭分流时，自动将新连接切回系统直连，并**仅关闭经由手机代理的旧连接**，保留正在传输的企业内网/直连会话。
- **按目的地精细分流**：私网地址与显式直连规则优先，其次匹配自定义域名/CIDR 与远程规则集（支持 `.mrs` / `.yaml` / `.txt`），未匹配流量默认走系统直连。
- **macOS 原生菜单栏体验**：大号 `P`（蓝色分流中）/ `D`（单色直连）状态栏图标、内联热点设置与一键识别当前 Wi-Fi、开机自启开关、默认收起的活跃连接与规则双页折叠面板。

## 快速开始

### macOS（14 及以上）

安装 Rust 与 Xcode Command Line Tools 后运行：

```sh
bash scripts/build.sh && open dist/NetPilot.app
```

脚本会自动按本机架构下载并校验 Mihomo，生成本地签名的 `dist/NetPilot.app`。

1. 点击菜单栏图标，展开 **「热点设置」**。
2. 点击 **「识别 Wi-Fi」** 自动填入当前 Wi-Fi 网卡、热点名称与网关 IP（也可手动填写；若系统隐藏 SSID，留空热点名称并保留网关 IPv4 即可按网关匹配），确认手机代理端口（如 `7890`）并保存。
3. 手机端代理软件需开启「允许局域网连接」。

### Windows x64

从源码打包运行：

```powershell
./scripts/build.ps1
```

启动 `dist/windows-x64/netpilot-core.exe`（`mihomo.exe` 需位于同目录）。在另一个 PowerShell 中运行 `./netpilot-core.exe config-path` 查看配置文件路径，设置 `hotspot.interface`（如 `WLAN`）与 `hotspot.ssids`（或留空并指定 `hotspot.proxy_host`），保存后自动热重载。

## 接入浏览器、桌面客户端与终端

- **浏览器 / 系统自动代理（PAC）**：在网络或浏览器自动代理设置中填写 `http://127.0.0.1:7900/proxy.pac`（PAC 脚本返回 `PROXY 127.0.0.1:7899; DIRECT`，即使退出 NetPilot 也会自动回退直连）。
- **桌面客户端**：遵循系统代理的客户端可直接使用上述 PAC；支持独立代理设置的客户端可填写本地混合代理 `http://127.0.0.1:7899`（同时支持 HTTP 与 SOCKS5）。企业内网域名可在菜单栏显式设为直连，或加入客户端的 `NO_PROXY` 排除列表。
- **终端工具**：

```sh
export http_proxy=http://127.0.0.1:7899
export https_proxy="$http_proxy"
export no_proxy=localhost,127.0.0.1,::1
```

## 规则与订阅

- 默认内置常见开发与 AI 服务的通用分流规则（OpenAI / ChatGPT / Anthropic / Google / GitHub），可在菜单栏自由增删或切换为直连。
- 在菜单栏 **「分流规则 → 订阅规则集」** 中可添加单个 Mihomo 规则集的 HTTPS 链接（支持 `domain` / `ipcidr` / `classical` 类型及 `mrs` / `yaml` / `text` 格式，按 24 小时自动缓存刷新）。
- 常用命令行：

```sh
netpilot-core status
netpilot-core hotspot auto
netpilot-core hotspot off
netpilot-core provider add github https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geosite/github.mrs domain mrs
```

配置文件默认位于 `~/.config/netpilot/config.json`（支持 `--config PATH` 指定路径），同目录的 `routing.jsonl` 会记录每次出口切换与断连统计。

## 致谢与许可

- 本项目源码基于 [MIT License](LICENSE) 开源。
- 代理内核使用 [Mihomo v1.19.34](https://github.com/MetaCubeX/mihomo/tree/v1.19.34)，其许可证见 [scripts/MIHOMO-LICENSE](scripts/MIHOMO-LICENSE)。
- 详细变更记录见 [CHANGELOG.md](CHANGELOG.md)。
