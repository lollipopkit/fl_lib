//! Live change events over server-sent events.

use super::*;

impl<S: Store> SyncClient<S> {
    /// What other devices write, as long as it is read: connected again after
    /// a drop, waiting longer each time up to a minute. Ends when signed out.
    pub fn events(self: Arc<Self>) -> impl Stream<Item = Event> + Send + 'static {
        self.events_on("sync")
    }

    /// A team's changes of members and key ([Event::Team]), as [events].
    pub fn team_events(self: Arc<Self>) -> impl Stream<Item = Event> + Send + 'static {
        self.events_on("team")
    }

    fn events_on(self: Arc<Self>, chan: &'static str) -> impl Stream<Item = Event> + Send + 'static {
        struct Listen<S: Store> {
            chan: &'static str,
            sync: Arc<SyncClient<S>>,
            body: Option<Body>,
            buffer: Vec<u8>,
            wait: Duration,
            /// Waited before the next connection, once [Event::Lost] is out.
            retry: Option<Duration>,
        }
        let start = Listen { chan, sync: self, body: None, buffer: Vec::new(), wait: Duration::from_secs(1), retry: None };
        futures_util::stream::unfold(start, |mut st| async move {
            if let Some(wait) = st.retry.take() {
                tokio::time::sleep(wait).await;
            }
            loop {
                if let Some(event) = take_event(&mut st.buffer) {
                    if let Some(event) = st.sync.heard(&event) {
                        return Some((event, st));
                    }
                    continue;
                }
                let Some(body) = st.body.as_mut() else {
                    match st.sync.listen(st.chan).await {
                        Ok(body) => {
                            st.body = Some(body);
                            st.buffer.clear();
                            st.wait = Duration::from_secs(1);
                            return Some((Event::Connected, st));
                        }
                        Err(e) if e.kind == Kind::SignedOut => return None,
                        Err(e) => {
                            let wait = st.wait;
                            st.wait = (st.wait * 2).min(MAX_BACKOFF);
                            st.retry = Some(wait);
                            return Some((Event::Lost(e.to_string()), st));
                        }
                    }
                };
                let lost = match body.next().await {
                    Some(Ok(chunk)) => {
                        st.buffer.extend_from_slice(&chunk);
                        continue;
                    }
                    Some(Err(e)) => format!("the event stream failed: {e}"),
                    None => "the event stream ended".to_string(),
                };
                st.body = None;
                let wait = st.wait;
                st.wait = (st.wait * 2).min(MAX_BACKOFF);
                st.retry = Some(wait);
                return Some((Event::Lost(lost), st));
            }
        })
    }

    pub(super) async fn listen(&self, chan: &str) -> Result<Body, Error> {
        let response = self.send(Method::GET, &format!("/sse/listen?chan={chan}"), |r| r.header(header::ACCEPT, "text/event-stream")).await?;
        let stream = response.headers().get(header::CONTENT_TYPE).and_then(|v| v.to_str().ok()).is_some_and(|v| v.starts_with("text/event-stream"));
        if response.status() != StatusCode::OK {
            return Err(refusal(response).await);
        }
        if !stream {
            // `{"code": 2}`, or another refusal as JSON.
            return Err(self.json::<Value>(response).await.err().unwrap_or_else(|| Error::new(Kind::Invalid, "not an event stream")));
        }
        Ok(Box::pin(response.bytes_stream()))
    }

    /// An event of this app (of this team, or of none) written by another
    /// device.
    pub(super) fn heard(&self, value: &Value) -> Option<Event> {
        let team = value["team"].as_str().map(|t| canonical(t).unwrap_or_default());
        if team.as_deref() != self.team.as_ref().map(|t| t.id.as_str()) {
            return None;
        }
        if value["event"] == "team" {
            return value["change"].as_str().map(|c| Event::Team { change: c.to_string() });
        }
        if value["app"] != self.app.as_str() {
            return None;
        }
        if value["event"] == "log" {
            return value["seq"].as_i64().map(|seq| Event::Log { seq });
        }
        if value["event"] != "sync" {
            return None;
        }
        let name = value["name"].as_str()?.to_string();
        let etag = value["etag"].as_str().map(str::to_string);
        let own = etag.is_some() && self.written.lock().unwrap_or_else(|e| e.into_inner()).get(&name) == etag.as_ref();
        (!own).then_some(Event::Changed { name, etag })
    }
}

/// The next complete event in [buffer] (its `data:` lines as JSON), taken
/// out; comments (`: ping`) and other fields are skipped.
fn take_event(buffer: &mut Vec<u8>) -> Option<Value> {
    loop {
        let end = buffer.windows(2).position(|w| w == b"\n\n")?;
        let block: Vec<u8> = buffer.drain(..end + 2).collect();
        let text = String::from_utf8_lossy(&block);
        let data: String = text.lines().filter_map(|l| l.strip_prefix("data:")).map(str::trim_start).collect::<Vec<_>>().join("\n");
        if data.is_empty() {
            continue;
        }
        if let Ok(value) = serde_json::from_str(&data) {
            return Some(value);
        }
    }
}
