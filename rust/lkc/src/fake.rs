//! A fake IdP and homebase on loopback for the tests: one handler answers
//! every request, and every request is kept.

use std::sync::{Arc, Mutex};

use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::TcpListener;

#[derive(Debug, Clone)]
pub struct Request {
    pub method: String,
    /// Path and query.
    pub target: String,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

impl Request {
    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers.iter().find(|(n, _)| n.eq_ignore_ascii_case(name)).map(|(_, v)| v.as_str())
    }

    pub fn path(&self) -> &str {
        self.target.split('?').next().unwrap_or_default()
    }

    pub fn form(&self, key: &str) -> Option<String> {
        url::form_urlencoded::parse(&self.body).find(|(k, _)| k == key).map(|(_, v)| v.into_owned())
    }
}

pub struct Response {
    pub status: u16,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
    /// The connection closed with no answer at all.
    pub drop: bool,
}

impl Response {
    pub fn json(status: u16, value: serde_json::Value) -> Self {
        Self { status, headers: vec![("content-type".into(), "application/json".into())], body: value.to_string().into_bytes(), drop: false }
    }

    pub fn status(status: u16) -> Self {
        Self { status, headers: vec![], body: vec![], drop: false }
    }

    pub fn dropped() -> Self {
        Self { status: 0, headers: vec![], body: vec![], drop: true }
    }

    pub fn header(mut self, name: &str, value: &str) -> Self {
        self.headers.push((name.into(), value.into()));
        self
    }

    pub fn body(mut self, body: impl Into<Vec<u8>>) -> Self {
        self.body = body.into();
        self
    }
}

type Handler = dyn Fn(&Request) -> Response + Send + Sync;

pub struct Fake {
    pub base: String,
    pub seen: Arc<Mutex<Vec<Request>>>,
}

impl Fake {
    pub async fn start(handler: impl Fn(&Request) -> Response + Send + Sync + 'static) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let seen = Arc::new(Mutex::new(Vec::new()));
        let handler: Arc<Handler> = Arc::new(handler);
        let kept = seen.clone();
        tokio::spawn(async move {
            while let Ok((socket, _)) = listener.accept().await {
                let (handler, kept) = (handler.clone(), kept.clone());
                tokio::spawn(async move {
                    let (read, mut write) = socket.into_split();
                    let mut read = BufReader::new(read);
                    let mut line = String::new();
                    if read.read_line(&mut line).await.unwrap_or(0) == 0 {
                        return;
                    }
                    let mut parts = line.split_whitespace();
                    let (method, target) = (parts.next().unwrap_or_default().to_string(), parts.next().unwrap_or_default().to_string());
                    let mut headers = Vec::new();
                    loop {
                        let mut h = String::new();
                        read.read_line(&mut h).await.unwrap();
                        let h = h.trim_end();
                        if h.is_empty() {
                            break;
                        }
                        if let Some((n, v)) = h.split_once(':') {
                            headers.push((n.trim().to_string(), v.trim().to_string()));
                        }
                    }
                    let len = headers.iter().find(|(n, _)| n.eq_ignore_ascii_case("content-length")).and_then(|(_, v)| v.parse().ok()).unwrap_or(0);
                    let mut body = vec![0; len];
                    read.read_exact(&mut body).await.unwrap();
                    let request = Request { method, target, headers, body };
                    kept.lock().unwrap().push(request.clone());
                    let response = handler(&request);
                    if response.drop {
                        return;
                    }
                    let mut head = format!("HTTP/1.1 {} X\r\ncontent-length: {}\r\nconnection: close\r\n", response.status, response.body.len());
                    for (n, v) in &response.headers {
                        head.push_str(&format!("{n}: {v}\r\n"));
                    }
                    head.push_str("\r\n");
                    let _ = write.write_all(head.as_bytes()).await;
                    let _ = write.write_all(&response.body).await;
                    let _ = write.shutdown().await;
                });
            }
        });
        Self { base, seen }
    }

    pub fn requests(&self, path: &str) -> Vec<Request> {
        self.seen.lock().unwrap().iter().filter(|r| r.path() == path).cloned().collect()
    }

    /// The issuer this fake serves the IdP under.
    pub fn issuer(&self) -> String {
        format!("{}/auth/v1/", self.base)
    }
}

/// The IdP's discovery document for [fake]'s issuer.
pub fn discovery(base: &str) -> serde_json::Value {
    serde_json::json!({
        "issuer": format!("{base}/auth/v1/"),
        "token_endpoint": format!("{base}/auth/v1/oidc/token"),
        "revocation_endpoint": format!("{base}/auth/v1/oidc/token/revoke"),
    })
}
