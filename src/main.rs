mod config;
mod engine;
mod pac;
mod phone;
use anyhow::{ensure, Context, Result};
use config::Config;
use serde_json::{json, Value};
use std::{
    io::Write,
    net::Ipv4Addr,
    path::{Path, PathBuf},
    time::Duration,
};
use tokio::{
    net::TcpListener,
    process::Command,
    time::{sleep, Instant},
};

async fn probe(c: &Config) -> (Option<phone::Phone>, bool, String, String) {
    if c.hotspot.mode == "off" {
        return (None, false, "已关闭，全部直连".into(), "manual_off".into());
    }
    let settings = c.hotspot.clone();
    match tokio::task::spawn_blocking(move || phone::discover(&settings)).await {
        Ok(Ok(phone)) => match phone.connect().await {
            Ok(_) => (Some(phone), true, "手机代理可用，按目的地分流".into(), String::new()),
            Err(e) => (None, true, "手机代理不可达，全部直连".into(), e.to_string()),
        },
        Ok(Err(e)) => (None, false, format!("{e}，全部直连"), e.to_string()),
        Err(e) => (None, false, e.to_string(), e.to_string()),
    }
}
fn atomic_write(path: &Path, value: &Value) -> Result<()> {
    let mut f = tempfile::NamedTempFile::new_in(path.parent().context("缺少配置目录")?)?;
    f.write_all(&serde_json::to_vec_pretty(value)?)?;
    f.persist(path)?;
    Ok(())
}
async fn stopped() {
    #[cfg(unix)]
    {
        let mut term = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
            .expect("signal");
        tokio::select! {_=term.recv()=>(),_=tokio::signal::ctrl_c()=>()}
    }
    #[cfg(windows)]
    {
        let _ = tokio::signal::ctrl_c().await;
    }
}
async fn daemon(path: &Path, c: Config) -> Result<()> {
    let dir = path.parent().context("配置目录不存在")?.join("mihomo");
    let pac_listener = TcpListener::bind((Ipv4Addr::LOCALHOST, c.pac_port))
        .await
        .context("PAC 端口已占用，请退出旧版")?;
    let listen = c.listen_addr;
    let pac_port = c.pac_port;
    let mut ports = vec![listen];
    if listen.port() != 7898 {
        ports.push("127.0.0.1:7898".parse()?);
    }
    for addr in &ports {
        TcpListener::bind(*addr)
            .await
            .with_context(|| format!("代理端口 {addr} 已占用"))?;
    }
    let controller = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).await?;
    let addr = controller.local_addr()?.to_string();
    let secret = uuid::Uuid::new_v4().to_string();
    let api = engine::Api::new(&addr, &secret);
    let mut loaded = engine::profile(&c, None, &addr, &secret)?;
    let startup = engine::write_private(&dir, &loaded)?;
    drop(controller);
    let mut child = Command::new(engine::binary()?)
        .args(["-d"])
        .arg(&dir)
        .arg("-f")
        .arg(startup)
        .kill_on_drop(true)
        .spawn()?;
    let mut shutdown = Box::pin(stopped());
    let deadline = Instant::now() + Duration::from_secs(60);
    while !api.ready() {
        ensure!(child.try_wait()?.is_none(), "Mihomo 启动失败");
        ensure!(Instant::now() < deadline, "Mihomo 控制端口未就绪");
        tokio::select! { _=&mut shutdown=>{child.kill().await?;return Ok(())}, _=sleep(Duration::from_millis(100))=>() }
    }
    for p in ports {
        tokio::net::TcpStream::connect(p)
            .await
            .with_context(|| format!("Mihomo 未监听 {p}"))?;
    }
    println!("代理 http://{listen}  •  PAC http://127.0.0.1:{pac_port}/proxy.pac");
    println!("热点设置与规则：{}", path.display());
    tokio::spawn(pac::serve(pac_listener, listen));
    let runtime = path.with_file_name("runtime.json");
    let mut current = c;
    let mut endpoint = None;
    let mut selected = false;
    let mut last_phone = None;
    let mut reason = String::new();
    let mut next_probe = Instant::now();
    let mut last_bytes = Vec::new();
    let mut warning = None;
    let mut last_status = Value::Null;
    let mut last_event = None;
    let mut last_detail = String::new();
    let mut next_snapshot = Instant::now();
    let mut fail_streak: u8 = 0;

    loop {
        ensure!(child.try_wait()?.is_none(), "Mihomo 已退出");
        if let Ok(raw) = std::fs::read(path) {
            if raw != last_bytes {
                match serde_json::from_slice::<Config>(&raw)
                    .map_err(anyhow::Error::from)
                    .and_then(|v| {
                        config::validate(&v)?;
                        ensure!(
                            v.listen_addr == listen && v.pac_port == pac_port,
                            "端口变更需要重启"
                        );
                        engine::profile(&v, None, &addr, &secret)?;
                        Ok(v)
                    }) {
                    Ok(v) => {
                        current = v;
                        next_probe = Instant::now();
                        fail_streak = 0;
                        warning = None;
                    }
                    Err(e) => warning = Some(format!("沿用上次配置：{e}")),
                }
                last_bytes = raw;
            }
        }
        if Instant::now() >= next_probe {
            let (probed, wifi_attached, probed_reason, detail) = probe(&current).await;
            if let Some(p) = probed {
                fail_streak = 0;
                endpoint = Some(p.addr);
                last_phone = Some(p);
                reason = probed_reason;
                last_detail.clear();
            } else if current.hotspot.mode == "off" || !wifi_attached || last_phone.is_none() {
                // 手动关闭或 Wi-Fi 热点已实际断开：立即切直连
                fail_streak = 0;
                last_phone = None;
                reason = probed_reason;
                last_detail = detail;
            } else {
                // Wi-Fi 仍连着手机热点，容忍短暂省电抖动，连续 3 次探测失败才切直连
                fail_streak = fail_streak.saturating_add(1);
                if fail_streak >= 3 {
                    last_phone = None;
                    reason = probed_reason;
                    last_detail = detail;
                }
            }
            next_probe = Instant::now() + Duration::from_secs(3);
        }
        let active = last_phone.is_some();
        let mut closed = 0;
        let result = (|| -> Result<()> {
            if !active && selected {
                api.select(false)?;
                closed = api.disconnect_phone()?;
                selected = false;
            }
            let desired = engine::profile(&current, endpoint, &addr, &secret)?;
            if desired != loaded {
                api.load(&desired)?;
                api.select(active)?;
                loaded = desired;
                selected = active;
            } else if selected != active {
                api.select(active)?;
                selected = active;
            }
            Ok(())
        })();
        let event = if result.is_err() {
            "switch_failed"
        } else if current.hotspot.mode == "off" {
            "manual_off"
        } else if selected {
            "phone_available"
        } else {
            "phone_unavailable"
        };
        if last_event != Some(event) {
            let timestamp = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)?
                .as_secs();
            let entry = json!({"unix_seconds":timestamp,"event":event,"egress":if result.is_err() {"unknown"} else if selected {"phone_for_selected"} else {"system_direct"},"closed_phone_connections":closed,"detail":last_detail});
            let log = std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(path.with_file_name("routing.jsonl"));
            match log.and_then(|mut f| writeln!(f, "{entry}")) {
                Ok(()) => last_event = Some(event),
                Err(e) => eprintln!("写入切换日志失败: {e}"),
            }
        }
        let msg = result
            .err()
            .map(|e| e.to_string())
            .or_else(|| warning.clone())
            .unwrap_or_else(|| reason.clone());
        let need_snapshot = Instant::now() >= next_snapshot;
        let connections = if need_snapshot {
            api.active_connections()
        } else {
            last_status["connections"].as_array().cloned().unwrap_or_default()
        };
        let status = json!({
            "pid": std::process::id(),
            "engine": "mihomo",
            "listen_addr": listen,
            "pac_url": format!("http://127.0.0.1:{pac_port}/proxy.pac"),
            "hotspot": {
                "active": selected,
                "reason": msg,
                "current_ssid": last_phone.as_ref().map(|p| p.ssid.as_str()).unwrap_or("")
            },
            "connections": connections
        });
        if status != last_status || need_snapshot {
            atomic_write(&runtime, &status)?;
            last_status = status;
            next_snapshot = Instant::now() + Duration::from_secs(2);
        }
        tokio::select! {_=&mut shutdown=>break,_=sleep(Duration::from_millis(450))=>()}
    }
    child.kill().await?;
    let _ = std::fs::remove_file(runtime);
    Ok(())
}

#[tokio::main]
async fn main() -> Result<()> {
    let mut args: Vec<_> = std::env::args().skip(1).collect();
    let mut path = std::env::var_os("NETPILOT_CONFIG")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            PathBuf::from(
                std::env::var_os(if cfg!(windows) { "USERPROFILE" } else { "HOME" })
                    .unwrap_or_default(),
            )
            .join(".config/netpilot/config.json")
        });
    if let Some(i) = args.iter().position(|a| a == "--config") {
        ensure!(i + 1 < args.len(), "缺少配置路径");
        path = args.remove(i + 1).into();
        args.remove(i);
    }
    path = std::path::absolute(path)?;
    let c = config::load(&path)?;
    match args.iter().map(String::as_str).collect::<Vec<_>>().as_slice(){
        []|["daemon"]=>daemon(&path,c).await?,
        ["config-path"]=>println!("{}",path.display()),
        ["test"]=>println!("{}",probe(&c).await.2),
        ["status"]=>println!("{}",std::fs::read_to_string(path.with_file_name("runtime.json")).context("尚未启动")?),
        ["hotspot",mode @ ("off"|"auto") ]=>{let mut v:Value=serde_json::from_slice(&std::fs::read(&path)?)?;v["hotspot"]["mode"]=json!(mode);atomic_write(&path,&v)?;},
        ["provider","add",name,url,behavior,format]=>{
            let mut v:Value=serde_json::from_slice(&std::fs::read(&path)?)?;
            if v["rule_providers"].is_null(){v["rule_providers"]=json!([]);}
            let items=v["rule_providers"].as_array_mut().context("rule_providers 必须为数组")?;
            items.retain(|p|p["name"].as_str()!=Some(name));items.push(json!({"name":name,"url":url,"behavior":behavior,"format":format}));
            engine::profile(&serde_json::from_value(v.clone())?,None,"127.0.0.1:0","")?;atomic_write(&path,&v)?;
        },
        _=>println!("netpilot-core [daemon | status | test | config-path | hotspot auto/off | provider add NAME HTTPS_URL domain/ipcidr/classical yaml/text/mrs] [--config PATH]")
    }
    Ok(())
}
