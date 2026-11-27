use crate::config::Hotspot;
use anyhow::{ensure, Context, Result};
use std::{
    net::{Ipv4Addr, SocketAddrV4},
    process::Command,
    time::Duration,
};
use tokio::{
    net::{TcpSocket, TcpStream},
    time::timeout,
};

#[derive(Clone, Debug)]
pub struct Phone {
    pub addr: SocketAddrV4,
    pub source: Ipv4Addr,
    pub ssid: String,

    #[cfg(target_os = "macos")]
    index: std::num::NonZeroU32,
}

fn output(cmd: &mut Command) -> Result<String> {
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        cmd.creation_flags(0x08000000);
    }
    let out = cmd.output()?;
    ensure!(out.status.success(), "热点网卡不可用");
    Ok(String::from_utf8_lossy(&out.stdout).trim().to_owned())
}

pub fn discover(c: &Hotspot) -> Result<Phone> {
    ensure!(c.mode != "off", "已关闭");
    #[cfg(target_os = "macos")]
    let (source, gateway, ssid, index) = {
        let arg = &c.interface;
        let source = output(Command::new("/usr/sbin/ipconfig").args(["getifaddr", arg]))?;
        let gateway = output(Command::new("/usr/sbin/ipconfig").args(["getoption", arg, "router"]))
            .unwrap_or_default();
        let info = if c.mode == "auto" && !c.ssids.is_empty() {
            output(Command::new("/usr/sbin/ipconfig").args(["getsummary", arg]))?
        } else {
            String::new()
        };
        let ssid = info
            .lines()
            .find_map(|l| l.trim().strip_prefix("SSID : "))
            .unwrap_or("")
            .trim()
            .to_string();
        let name = std::ffi::CString::new(arg.as_str())?;
        let index = std::num::NonZeroU32::new(unsafe { libc::if_nametoindex(name.as_ptr()) })
            .context("网卡不存在")?;
        (source, gateway, ssid, index)
    };
    #[cfg(windows)]
    let (source, gateway, ssid) = {
        let adapter = ipconfig::get_adapters()?
            .into_iter()
            .find(|a| a.friendly_name().eq_ignore_ascii_case(&c.interface))
            .context("找不到配置的热点网卡")?;
        let source = adapter
            .ip_addresses()
            .iter()
            .find(|a| a.is_ipv4())
            .context("热点网卡没有 IPv4 地址")?
            .to_string();
        let gateway = adapter
            .gateways()
            .iter()
            .find(|a| a.is_ipv4())
            .map(ToString::to_string)
            .unwrap_or_default();
        let ssid = if c.ssids.is_empty() || c.mode != "auto" {
            String::new()
        } else {
            let script = r#"[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false); (Get-NetConnectionProfile -InterfaceAlias $env:NETPILOT_ADAPTER -ErrorAction Stop).Name"#;
            output(
                Command::new("powershell.exe")
                    .args(["-NoProfile", "-NonInteractive", "-Command", script])
                    .env("NETPILOT_ADAPTER", &c.interface),
            )?
        };
        (source, gateway, ssid)
    };
    let gateway = gateway.parse::<Ipv4Addr>().ok();
    if c.mode == "auto" {
        ensure!(
            if c.ssids.is_empty() {
                !c.proxy_host.is_empty()
                    && c.proxy_host.parse::<Ipv4Addr>().ok() == gateway
                    && gateway.is_some()
            } else {
                c.ssids.iter().any(|s| s == &ssid)
            },
            "请设置手机热点名称，或指定手机网关地址"
        );
    }
    let ip = if c.proxy_host.is_empty() {
        gateway.context("热点网卡没有 IPv4 网关")?
    } else {
        c.proxy_host.parse()?
    };
    Ok(Phone {
        addr: SocketAddrV4::new(ip, c.proxy_port),
        source: source.parse()?,
        ssid,

        #[cfg(target_os = "macos")]
        index,
    })
}

impl Phone {
    pub async fn connect(&self) -> Result<TcpStream> {
        let sock = TcpSocket::new_v4()?;
        #[cfg(target_os = "macos")]
        socket2::SockRef::from(&sock).bind_device_by_index_v4(Some(self.index))?;
        sock.bind(SocketAddrV4::new(self.source, 0).into())?;
        Ok(timeout(Duration::from_millis(2500), sock.connect(self.addr.into())).await??)
    }
}
