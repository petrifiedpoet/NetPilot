use bytes::Bytes;
use http_body_util::Full;
use hyper::{service::service_fn, Response};
use hyper_util::rt::TokioIo;
use std::{convert::Infallible, net::SocketAddr, sync::Arc};
use tokio::net::TcpListener;

pub async fn serve(listener: TcpListener, proxy: SocketAddr) -> std::io::Result<()> {
    let script=Arc::new(format!("function FindProxyForURL(url,host){{if(isPlainHostName(host)||host==='127.0.0.1'||host==='[::1]'||dnsDomainIs(host,'.local')||dnsDomainIs(host,'.lan'))return 'DIRECT';return 'PROXY {proxy}; DIRECT';}}"));
    loop {
        let (socket, _) = listener.accept().await?;
        let script = script.clone();
        tokio::spawn(async move {
            let service = service_fn(move |req: hyper::Request<hyper::body::Incoming>| {
                let ok = req.method() == hyper::Method::GET && req.uri().path() == "/proxy.pac";
                let response = Response::builder()
                    .status(if ok { 200 } else { 404 })
                    .header("Content-Type", "application/x-ns-proxy-autoconfig")
                    .header("Cache-Control", "no-store")
                    .body(Full::new(Bytes::from(if ok {
                        script.to_string()
                    } else {
                        String::new()
                    })))
                    .unwrap();
                async move { Ok::<_, Infallible>(response) }
            });
            let _ = tokio::time::timeout(
                std::time::Duration::from_secs(10),
                hyper::server::conn::http1::Builder::new()
                    .keep_alive(false)
                    .serve_connection(TokioIo::new(socket), service),
            )
            .await;
        });
    }
}
