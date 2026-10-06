use crate::{model::*, store::Store};
use serde_json::Value;
use std::path::Path;
use tokio::sync::{mpsc, oneshot};

struct Job {
    source: Option<String>,
    op: String,
    data: Value,
    reply: oneshot::Sender<Result<Value>>,
}
#[derive(Clone)]
pub struct Service {
    sender: mpsc::Sender<Job>,
}
impl Service {
    pub fn start(path: &Path) -> Result<Self> {
        let mut store = Store::open(path)?;
        store.recover()?;
        let (sender, mut receiver) = mpsc::channel::<Job>(256);
        std::thread::Builder::new()
            .name("notification-store".into())
            .spawn(move || {
                while let Some(job) = receiver.blocking_recv() {
                    let result = match job.op.as_str() {
                        "_authenticate" => store.authenticate(job.data.as_str().unwrap_or("")),
                        "_tick" => store.tick().map(|_| Value::Null),
                        "_delivery.next" => store.claim_delivery(),
                        "_delivery.result" => store.delivery_result(job.data),
                        _ => store.command(job.source.as_deref(), &job.op, job.data),
                    };
                    let _ = job.reply.send(result);
                }
            })
            .map_err(|e| ApiError::new("unavailable", e))?;
        Ok(Self { sender })
    }
    pub async fn call(&self, source: Option<&str>, op: &str, data: Value) -> Result<Value> {
        let (reply, rx) = oneshot::channel();
        self.sender
            .try_send(Job {
                source: source.map(str::to_string),
                op: op.into(),
                data,
                reply,
            })
            .map_err(|_| ApiError::new("unavailable", "notification service busy or stopped"))?;
        rx.await
            .map_err(|_| ApiError::new("unavailable", "notification service stopped"))?
    }
    pub async fn external(&self, source: &str, request: Envelope) -> Result<Value> {
        if request.v != 1 || request.request_id.len() > 200 {
            return Err(ApiError::invalid("unsupported version or request id"));
        }
        if ![
            "notification.create",
            "notification.update",
            "notification.cancel",
            "notification.get",
            "notification.list",
            "notification.mark_read",
            "notification.archive",
            "events.list",
            "events.subscribe",
        ]
        .contains(&request.op.as_str())
        {
            return Err(ApiError::invalid("unknown command"));
        }
        self.call(Some(source), &request.op, request.data).await
    }
    pub async fn authenticate(&self, token: &str) -> Result<String> {
        self.call(None, "_authenticate", Value::String(token.into()))
            .await?
            .as_str()
            .map(str::to_string)
            .ok_or_else(|| ApiError::new("unauthorized", "invalid token"))
    }
}
pub async fn run_workers(service: Service) {
    let ticker = service.clone();
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(std::time::Duration::from_millis(200));
        loop {
            interval.tick().await;
            if let Err(e) = ticker.call(None, "_tick", Value::Null).await {
                eprintln!("notification tick: {}", e.message);
            }
        }
    });
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(5))
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .expect("HTTP client");
    for _ in 0..4 {
        let service = service.clone();
        let client = client.clone();
        tokio::spawn(async move {
            loop {
                match service.call(None, "_delivery.next", Value::Null).await {
                    Ok(job) if !job.is_null() => {
                        let response = client
                            .post(job["url"].as_str().unwrap())
                            .header("Content-Type", "application/json")
                            .body(job["body"].as_str().unwrap().to_string())
                            .send()
                            .await;
                        let (success, error) = match response {
                            Ok(r) => (r.status().is_success(), format!("HTTP {}", r.status())),
                            Err(e) => (false, e.to_string()),
                        };
                        let result = serde_json::json!({"id":job["id"],"success":success,"error":if success{None}else{Some(error)}});
                        while let Err(e) =
                            service.call(None, "_delivery.result", result.clone()).await
                        {
                            eprintln!("callback persistence: {}", e.message);
                            tokio::time::sleep(std::time::Duration::from_secs(1)).await;
                        }
                    }
                    _ => tokio::time::sleep(std::time::Duration::from_millis(500)).await,
                }
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::sync::{
        atomic::{AtomicUsize, Ordering},
        Arc,
    };
    #[tokio::test]
    async fn webhook_retries_same_event_after_http_failure() {
        let (tx, mut rx) = tokio::sync::mpsc::channel::<Value>(100);
        let count = Arc::new(AtomicUsize::new(0));
        let app = axum::Router::new().route(
            "/callback",
            axum::routing::post(move |axum::Json(body): axum::Json<Value>| {
                let tx = tx.clone();
                let count = count.clone();
                async move {
                    let _ = tx.send(body).await;
                    if count.fetch_add(1, Ordering::SeqCst) == 0 {
                        axum::http::StatusCode::SERVICE_UNAVAILABLE
                    } else {
                        axum::http::StatusCode::NO_CONTENT
                    }
                }
            }),
        );
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        let service = Service::start(Path::new(":memory:")).unwrap();
        service
            .call(
                None,
                "endpoints.create",
                json!({"id":"cb","source":"desktop","url":format!("http://{address}/callback")}),
            )
            .await
            .unwrap();
        service
            .call(
                None,
                "notification.create",
                json!({"client_message_id":"one","title":"test","callback_endpoint_id":"cb"}),
            )
            .await
            .unwrap();
        run_workers(service.clone()).await;
        let first = tokio::time::timeout(std::time::Duration::from_secs(5), rx.recv())
            .await
            .unwrap()
            .unwrap();
        let retried = tokio::time::timeout(std::time::Duration::from_secs(10), async {
            loop {
                let item = rx.recv().await.unwrap();
                if item["event_id"] == first["event_id"] {
                    break item;
                }
            }
        })
        .await
        .unwrap();
        assert_eq!(first, retried);
        server.abort();
    }
}
