use crate::config::{Config, Rule};
use anyhow::{ensure, Context, Result};
use serde_json::{json, Map, Value};
use std::{
    collections::HashSet,
    net::{IpAddr, SocketAddrV4},
    path::{Path, PathBuf},
    time::Duration,
};

fn rule(r: &Rule) -> Result<String> {
    let pat = r.pattern.trim().trim_end_matches('.').to_ascii_lowercase();
    let target = if r.hotspot { "SELECTED" } else { "DIRECT" };
    if let Ok(ip) = pat.parse::<IpAddr>() {
        let bits = if ip.is_ipv4() { 32 } else { 128 };
        return Ok(format!("IP-CIDR,{ip}/{bits},{target},no-resolve"));
    }
    if let Ok(net) = pat.parse::<ipnet::IpNet>() {
        return Ok(format!("IP-CIDR,{net},{target},no-resolve"));
    }
    let (kind, name) = match pat.strip_prefix("*.") {
        Some(s) => ("DOMAIN-SUFFIX", s),
        None => ("DOMAIN", pat.as_str()),
    };
    ensure!(
        !name.is_empty()
            && name.split('.').all(|l| !l.is_empty()
                && l.bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')),
        "无效域名或网段: {pat}"
    );
    Ok(format!("{kind},{name},{target}"))
}

pub fn profile(c: &Config, addr: Option<SocketAddrV4>, api: &str, secret: &str) -> Result<Value> {
    let mut rules = vec![
        "DOMAIN-REGEX,^[^.]+$,DIRECT".to_string(),
        "DOMAIN-SUFFIX,local,DIRECT".into(),
        "DOMAIN-SUFFIX,lan,DIRECT".into(),
    ];
    for net in [
        "127.0.0.0/8",
        "10.0.0.0/8",
        "172.16.0.0/12",
        "192.168.0.0/16",
        "169.254.0.0/16",
        "100.64.0.0/10",
        "::1/128",
        "fc00::/7",
        "fe80::/10",
    ] {
        rules.push(format!("IP-CIDR,{net},DIRECT,no-resolve"));
    }
    for r in c
        .domains
        .iter()
        .filter(|r| !r.hotspot)
        .chain(c.domains.iter().filter(|r| r.hotspot))
    {
        rules.push(rule(r)?);
    }
    let mut providers = Map::new();
    let mut seen = HashSet::new();
    for p in &c.rule_providers {
        ensure!(
            !p.name.is_empty()
                && p.name.len() <= 80
                && p.name
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
                && seen.insert(&p.name),
            "规则集名称无效或重复"
        );
        ensure!(
            p.url.starts_with("https://")
                && matches!(p.behavior.as_str(), "domain" | "ipcidr" | "classical")
                && matches!(p.format.as_str(), "yaml" | "text" | "mrs")
                && !(p.format == "mrs" && p.behavior == "classical"),
            "无效规则集 {}",
            p.name
        );
        providers.insert(p.name.clone(),json!({"type":"http","behavior":p.behavior,"format":p.format,"url":p.url,"interval":86400,"path":format!("./rules/{}",p.name)}));
        rules.push(format!("RULE-SET,{},SELECTED,no-resolve", p.name));
    }
    rules.push("MATCH,DIRECT".into());
    let mut listeners = vec![
        json!({"name":"main","type":"mixed","listen":c.listen_addr.ip(),"port":c.listen_addr.port()}),
    ];
    if c.listen_addr.port() != 7898 {
        listeners.push(json!({"name":"compat","type":"mixed","listen":"127.0.0.1","port":7898}));
    }
    let mut nodes = vec![];
    let mut choices = vec!["DIRECT"];
    if let Some(a) = addr {
        nodes.push(json!({"name":"PHONE","type":c.hotspot.proxy_type,"server":a.ip(),"port":a.port(),"interface-name":c.hotspot.interface}));
        choices.push("PHONE");
    }
    Ok(
        json!({"mode":"rule","log-level":"warning","allow-lan":false,"tun":{"enable":false},"dns":{"enable":false},
    "profile":{"store-selected":false},"listeners":listeners,"external-controller":api,"secret":secret,"proxies":nodes,
    "proxy-groups":[{"name":"SELECTED","type":"select","proxies":choices}],"rule-providers":providers,"rules":rules}),
    )
}

pub fn binary() -> Result<PathBuf> {
    let name = if cfg!(windows) {
        "mihomo.exe"
    } else {
        "mihomo"
    };
    let path = std::env::var_os("NETPILOT_MIHOMO")
        .map(PathBuf::from)
        .unwrap_or(std::env::current_exe()?.with_file_name(name));
    ensure!(
        path.is_file(),
        "缺少 Mihomo，请使用打包版本或设置 NETPILOT_MIHOMO"
    );
    Ok(path)
}
pub struct Api {
    base: String,
    auth: String,
    client: ureq::Agent,
}
impl Api {
    pub fn new(addr: &str, secret: &str) -> Self {
        Self {
            base: format!("http://{addr}"),
            auth: format!("Bearer {secret}"),
            client: ureq::AgentBuilder::new()
                .timeout(Duration::from_secs(5))
                .build(),
        }
    }
    fn req(&self, method: &str, path: &str) -> ureq::Request {
        self.client
            .request(method, &format!("{}{path}", self.base))
            .set("Authorization", &self.auth)
    }
    pub fn ready(&self) -> bool {
        self.req("GET", "/version").call().is_ok()
    }
    pub fn load(&self, profile: &Value) -> Result<()> {
        self.req("PUT", "/configs?force=true")
            .send_json(json!({"payload":profile.to_string()}))
            .map_err(api_error)?;
        Ok(())
    }
    pub fn disconnect_phone(&self) -> Result<usize> {
        let mut closed = 0;
        let snapshot: Value = self
            .req("GET", "/connections")
            .call()
            .map_err(api_error)?
            .into_json()?;
        if let Some(connections) = snapshot["connections"].as_array() {
            for connection in connections {
                let through_phone = connection["chains"]
                    .as_array()
                    .is_some_and(|chain| chain.iter().any(|hop| hop.as_str() == Some("PHONE")));
                if through_phone {
                    let id = connection["id"].as_str().context("Mihomo 连接缺少 ID")?;
                    match self.req("DELETE", &format!("/connections/{id}")).call() {
                        Ok(_) => closed += 1,
                        Err(ureq::Error::Status(404, _)) => (),
                        Err(e) => return Err(api_error(e)),
                    }
                }
            }
        }
        Ok(closed)
    }
    pub fn select(&self, active: bool) -> Result<()> {
        self.req("PUT", "/proxies/SELECTED")
            .send_json(json!({"name":if active{"PHONE"}else{"DIRECT"}}))
            .map_err(api_error)?;
        Ok(())
    }
    pub fn active_connections(&self) -> Vec<Value> {
        let Ok(resp) = self.req("GET", "/connections").call() else {
            return vec![];
        };
        let Ok(snapshot) = resp.into_json::<Value>() else {
            return vec![];
        };
        let Some(connections) = snapshot["connections"].as_array() else {
            return vec![];
        };
        let mut grouped: std::collections::BTreeMap<(String, bool), (usize, String)> =
            std::collections::BTreeMap::new();
        for c in connections {
            let host = c["metadata"]["host"]
                .as_str()
                .filter(|s| !s.is_empty())
                .or_else(|| c["metadata"]["destinationIP"].as_str())
                .unwrap_or("")
                .to_string();
            if host.is_empty() {
                continue;
            }
            let through_phone = c["chains"]
                .as_array()
                .is_some_and(|chain| chain.iter().any(|hop| hop.as_str() == Some("PHONE")));
            let rule = c["rule"].as_str().unwrap_or("").to_string();
            let entry = grouped.entry((host, through_phone)).or_insert((0, rule));
            entry.0 += 1;
        }
        let mut items: Vec<(bool, usize, String, String)> = grouped
            .into_iter()
            .map(|((host, phone), (count, rule))| (phone, count, host, rule))
            .collect();
        items.sort_by(|a, b| b.0.cmp(&a.0).then(b.1.cmp(&a.1)).then(a.2.cmp(&b.2)));
        items
            .into_iter()
            .take(40)
            .map(|(phone, count, host, rule)| {
                json!({
                    "id": format!("{host}-{}", if phone { "p" } else { "d" }),
                    "host": host,
                    "egress": if phone { "phone" } else { "direct" },
                    "rule": rule,
                    "count": count
                })
            })
            .collect()
    }
}
fn api_error(e: ureq::Error) -> anyhow::Error {
    match e {
        ureq::Error::Status(code, r) => {
            anyhow::anyhow!("Mihomo {code}: {}", r.into_string().unwrap_or_default())
        }
        other => other.into(),
    }
}
pub fn write_private(dir: &Path, data: &Value) -> Result<PathBuf> {
    std::fs::create_dir_all(dir)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700))?;
    }
    let path = dir.join("config.yaml");
    std::fs::write(&path, serde_json::to_vec(data)?).context("写入 Mihomo 配置")?;
    Ok(path)
}
