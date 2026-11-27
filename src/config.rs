use anyhow::{ensure, Result};

use serde::Deserialize;
use std::{fs, net::SocketAddr, path::Path};

#[derive(Clone, Deserialize)]
pub struct Hotspot {
    pub mode: String,
    pub interface: String,
    pub ssids: Vec<String>,
    pub proxy_type: String,
    pub proxy_port: u16,
    pub proxy_host: String,
}
#[derive(Clone, Deserialize)]
pub struct Rule {
    pub pattern: String,
    pub hotspot: bool,
}
#[derive(Clone, Deserialize)]
pub struct Provider {
    pub name: String,
    pub url: String,
    pub behavior: String,
    pub format: String,
}
#[derive(Clone, Deserialize)]
pub struct Config {
    #[serde(default)]
    pub rule_providers: Vec<Provider>,
    #[serde(default = "default_pac")]
    pub pac_port: u16,
    pub listen_addr: SocketAddr,
    pub hotspot: Hotspot,
    pub domains: Vec<Rule>,
}

pub fn load(path: &Path) -> Result<Config> {
    if !path.exists() {
        if let Some(p) = path.parent() {
            fs::create_dir_all(p)?;
        }
        let data: serde_json::Value = serde_json::from_str(include_str!("default.json"))?;
        #[cfg(windows)]
        let data = {
            let mut data = data;
            let wifi = ipconfig::get_adapters()
                .unwrap_or_default()
                .into_iter()
                .find(|a| a.if_type() == ipconfig::IfType::Ieee80211);
            data["hotspot"]["interface"] = wifi
                .map(|a| a.friendly_name().to_owned())
                .unwrap_or_else(|| "Wi-Fi".into())
                .into();
            data
        };
        fs::write(path, serde_json::to_vec_pretty(&data)?)?;
    }
    let c: Config = serde_json::from_slice(&fs::read(path)?)?;
    validate(&c)?;
    Ok(c)
}
pub fn validate(c: &Config) -> Result<()> {
    ensure!(
        c.pac_port > 0
            && c.listen_addr.port() > 0
            && c.pac_port != c.listen_addr.port()
            && c.pac_port != 7898,
        "无效代理端口"
    );
    ensure!(c.listen_addr.ip().is_loopback(), "监听地址必须是本机地址");
    ensure!(
        matches!(c.hotspot.proxy_type.as_str(), "http" | "socks5"),
        "未知代理类型"
    );
    ensure!(
        matches!(c.hotspot.mode.as_str(), "auto" | "always" | "off"),
        "未知热点模式"
    );
    Ok(())
}

fn default_pac() -> u16 {
    7900
}
