use crate::{model::*, service::Service};
use axum::{
    Json, Router,
    extract::{
        DefaultBodyLimit, State, WebSocketUpgrade,
        ws::{Message, WebSocket},
    },
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    routing::{get, post},
};
use serde_json::{Value, json};
use std::{path::PathBuf, sync::Arc, time::Duration};
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
    sync::Semaphore,
};

#[derive(Clone)]
struct App {
    service: Service,
    connections: Arc<Semaphore>,
    requests: Arc<Semaphore>,
    port: u16,
}
fn status(e: &ApiError) -> StatusCode {
    match e.code.as_str() {
        "unauthorized" => StatusCode::UNAUTHORIZED,
        "not_found" => StatusCode::NOT_FOUND,
        "conflict" => StatusCode::CONFLICT,
        "unavailable" => StatusCode::SERVICE_UNAVAILABLE,
        "rate_limited" => StatusCode::TOO_MANY_REQUESTS,
        _ => StatusCode::BAD_REQUEST,
    }
}
fn error(e: ApiError) -> Response {
    (status(&e), Json(json!({"ok":false,"error":e}))).into_response()
}
async fn auth(app: &App, headers: &HeaderMap) -> Result<String> {
    let host = headers
        .get("host")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("");
    if ![
        format!("127.0.0.1:{}", app.port),
        format!("localhost:{}", app.port),
    ]
    .contains(&host.to_string())
        || headers.contains_key("origin")
    {
        return Err(ApiError::new(
            "unauthorized",
            "Host not allowed or browser Origin rejected",
        ));
    }
    let token = headers
        .get("authorization")
        .and_then(|h| h.to_str().ok())
        .and_then(|h| h.strip_prefix("Bearer "))
        .ok_or_else(|| ApiError::new("unauthorized", "Bearer token required"))?;
    app.service.authenticate(token).await
}
async fn bounded_request(
    State(app): State<App>,
    request: axum::extract::Request,
    next: axum::middleware::Next,
) -> Response {
    let _permit = match app.requests.try_acquire() {
        Ok(p) => p,
        Err(_) => return error(ApiError::new("unavailable", "request limit")),
    };
    match tokio::time::timeout(Duration::from_secs(15), next.run(request)).await {
        Ok(response) => response,
        Err(_) => error(ApiError::new(
            "unavailable",
            "request timeout; retry with the same client_message_id",
        )),
    }
}
async fn rpc(
    State(app): State<App>,
    headers: HeaderMap,
    Json(request): Json<Envelope>,
) -> Response {
    let source = match auth(&app, &headers).await {
        Ok(s) => s,
        Err(e) => return error(e),
    };
    let request_id = request.request_id.clone();
    match app.service.external(&source, request).await {
        Ok(data) => Json(response(&request_id, Ok(data))).into_response(),
        Err(e) => (status(&e), Json(response(&request_id, Err(e)))).into_response(),
    }
}
async fn create(State(app): State<App>, headers: HeaderMap, Json(data): Json<Value>) -> Response {
    let source = match auth(&app, &headers).await {
        Ok(s) => s,
        Err(e) => return error(e),
    };
    match app
        .service
        .call(Some(&source), "notification.create", data)
        .await
    {
        Ok(v) => (StatusCode::ACCEPTED, Json(v)).into_response(),
        Err(e) => error(e),
    }
}
async fn list(
    State(app): State<App>,
    headers: HeaderMap,
    axum::extract::Query(query): axum::extract::Query<std::collections::HashMap<String, String>>,
) -> Response {
    let source = match auth(&app, &headers).await {
        Ok(s) => s,
        Err(e) => return error(e),
    };
    let mut data = json!({});
    for (k, v) in query {
        data[&k] = if ["limit", "since", "until"].contains(&k.as_str()) {
            match v.parse::<i64>() {
                Ok(n) => json!(n),
                Err(_) => return error(ApiError::invalid("invalid integer filter")),
            }
        } else if ["unread", "archived", "callback_failed"].contains(&k.as_str()) {
            match v.parse::<bool>() {
                Ok(v) => json!(v),
                Err(_) => return error(ApiError::invalid("invalid boolean filter")),
            }
        } else if k == "cursor" {
            match serde_json::from_str(&v) {
                Ok(v) => v,
                Err(e) => return error(ApiError::invalid(e)),
            }
        } else {
            json!(v)
        };
    }
    match app
        .service
        .call(Some(&source), "notification.list", data)
        .await
    {
        Ok(v) => Json(v).into_response(),
        Err(e) => error(e),
    }
}
async fn detail(
    State(app): State<App>,
    headers: HeaderMap,
    axum::extract::Path(id): axum::extract::Path<String>,
) -> Response {
    rest(&app, &headers, "notification.get", json!({"id":id})).await
}
async fn update(
    State(app): State<App>,
    headers: HeaderMap,
    axum::extract::Path(id): axum::extract::Path<String>,
    Json(mut data): Json<Value>,
) -> Response {
    if !data.is_object() {
        return error(ApiError::invalid("object required"));
    }
    data["id"] = json!(id);
    rest(&app, &headers, "notification.update", data).await
}
async fn cancel(
    State(app): State<App>,
    headers: HeaderMap,
    axum::extract::Path(id): axum::extract::Path<String>,
) -> Response {
    rest(&app, &headers, "notification.cancel", json!({"id":id})).await
}
async fn rest(app: &App, headers: &HeaderMap, op: &str, data: Value) -> Response {
    let source = match auth(app, headers).await {
        Ok(s) => s,
        Err(e) => return error(e),
    };
    match app.service.call(Some(&source), op, data).await {
        Ok(v) => Json(v).into_response(),
        Err(e) => error(e),
    }
}
async fn events(
    State(app): State<App>,
    headers: HeaderMap,
    axum::extract::Query(q): axum::extract::Query<std::collections::HashMap<String, String>>,
) -> Response {
    let after = match q.get("after_seq").map(|s| s.parse::<i64>()).transpose() {
        Ok(v) => v.unwrap_or(0),
        Err(_) => return error(ApiError::invalid("invalid cursor")),
    };
    rest(&app, &headers, "events.list", json!({"after_seq":after})).await
}
async fn ws(State(app): State<App>, headers: HeaderMap, upgrade: WebSocketUpgrade) -> Response {
    let source = match auth(&app, &headers).await {
        Ok(s) => s,
        Err(e) => return error(e),
    };
    let permit = match app.connections.clone().try_acquire_owned() {
        Ok(p) => p,
        Err(_) => return error(ApiError::new("unavailable", "connection limit")),
    };
    upgrade
        .max_message_size(MAX_FRAME)
        .max_frame_size(MAX_FRAME)
        .on_upgrade(move |socket| async move {
            let _permit = permit;
            websocket(socket, app.service, source).await
        })
        .into_response()
}
async fn send_ws(socket: &mut WebSocket, value: Value) -> bool {
    matches!(
        tokio::time::timeout(
            Duration::from_secs(5),
            socket.send(Message::Text(value.to_string().into()))
        )
        .await,
        Ok(Ok(()))
    )
}
async fn websocket(mut socket: WebSocket, service: Service, source: String) {
    let mut cursor: Option<i64> = None;
    let mut interval = tokio::time::interval(Duration::from_millis(300));
    loop {
        tokio::select! {
            frame=socket.recv()=>{match frame {
                Some(Ok(Message::Text(text)))=>{let request=serde_json::from_str::<Envelope>(&text);let (rid,result)=match request{Ok(r)=>{let rid=r.request_id.clone();let subscribe=r.op=="events.subscribe";let result=service.external(&source,r).await;if subscribe{if let Ok(v)=&result{cursor=v["next_seq"].as_i64();}}(rid,result)},Err(e)=>(String::new(),Err(ApiError::invalid(e)))};if !send_ws(&mut socket,response(&rid,result)).await{break;}},
                Some(Ok(Message::Ping(p)))=>{if !matches!(tokio::time::timeout(Duration::from_secs(5),socket.send(Message::Pong(p))).await,Ok(Ok(()))){break;}},
                Some(Ok(Message::Pong(_)))=>{},_=>break,
            }},
            _=interval.tick(),if cursor.is_some()=>{match service.call(Some(&source),"events.list",json!({"after_seq":cursor})).await{Ok(v)=>{for event in v["events"].as_array().unwrap(){if !send_ws(&mut socket,event.clone()).await{return;}}cursor=v["next_seq"].as_i64();},Err(e)=>{send_ws(&mut socket,response("",Err(e))).await;cursor=None;}}}
        }
    }
}

pub async fn start(
    service: Service,
    port: u16,
    socket_path: PathBuf,
    ready: tokio::sync::oneshot::Sender<u16>,
) -> std::io::Result<()> {
    let listener = tokio::net::TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, port)).await?;
    let port = listener.local_addr()?.port();
    let app = App {
        service: service.clone(),
        connections: Arc::new(Semaphore::new(64)),
        requests: Arc::new(Semaphore::new(128)),
        port,
    };
    #[cfg(unix)]
    let unix = bind_unix(&socket_path)?;
    let router = Router::new()
        .route("/v1/rpc", post(rpc))
        .route("/v1/notifications", post(create).get(list))
        .route("/v1/notifications/{id}", get(detail).patch(update))
        .route("/v1/notifications/{id}/cancel", post(cancel))
        .route("/v1/events", get(events))
        .route("/v1/ws", get(ws))
        .layer(DefaultBodyLimit::max(MAX_FRAME))
        .layer(axum::middleware::from_fn_with_state(
            app.clone(),
            bounded_request,
        ))
        .with_state(app.clone());
    #[cfg(unix)]
    tokio::spawn(async move {
        loop {
            match unix.accept().await {
                Ok((stream, _)) => {
                    if let Ok(permit) = app.connections.clone().try_acquire_owned() {
                        let svc = service.clone();
                        tokio::spawn(async move {
                            let _permit = permit;
                            unix_client(stream, svc).await;
                        });
                    }
                }
                Err(e) => {
                    eprintln!("Unix accept: {e}");
                    tokio::time::sleep(Duration::from_secs(1)).await;
                }
            }
        }
    });
    let _ = ready.send(port);
    axum::serve(listener, router).await
}
#[cfg(unix)]
fn bind_unix(path: &std::path::Path) -> std::io::Result<tokio::net::UnixListener> {
    use std::os::unix::{
        fs::{FileTypeExt, PermissionsExt},
        net::UnixStream,
    };
    if let Ok(meta) = std::fs::symlink_metadata(path) {
        if !meta.file_type().is_socket() {
            return Err(std::io::Error::other("socket path occupied by non-socket"));
        }
        if UnixStream::connect(path).is_ok() {
            return Err(std::io::Error::other("another instance is listening"));
        }
        std::fs::remove_file(path)?;
    }
    let listener = tokio::net::UnixListener::bind(path)?;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
    Ok(listener)
}
#[cfg(unix)]
async fn unix_client(stream: tokio::net::UnixStream, service: Service) {
    let (read, mut write) = stream.into_split();
    let mut reader = BufReader::new(read);
    let mut source = None;
    let mut cursor: Option<i64> = None;
    let mut buffer = Vec::new();
    let mut interval = tokio::time::interval(Duration::from_millis(300));
    let auth_deadline = tokio::time::Instant::now() + Duration::from_secs(10);
    loop {
        tokio::select! {
            chunk = reader.fill_buf() => {
                let chunk = match chunk { Ok(c) if !c.is_empty() => c, _ => break };
                let end = chunk.iter().position(|b| *b == b'\n');
                let count = end.map_or(chunk.len(), |n| n + 1);
                if buffer.len() + count > MAX_FRAME { break; }
                buffer.extend_from_slice(&chunk[..count]);
                reader.consume(count);
                if end.is_none() { continue; }
                let request = serde_json::from_slice::<Envelope>(&buffer);
                buffer.clear();
                let (rid, result) = match request {
                    Ok(r) => {
                        let rid = r.request_id.clone();
                        let result = if r.v != 1 {
                            Err(ApiError::invalid("unsupported version"))
                        } else if source.is_none() {
                            if r.op != "auth" {
                                Err(ApiError::new("unauthorized", "first command must be auth"))
                            } else {
                                match service.authenticate(r.data["token"].as_str().unwrap_or("")).await {
                                    Ok(s) => { source = Some(s); Ok(json!({"authenticated": true})) }
                                    Err(e) => Err(e),
                                }
                            }
                        } else {
                            let subscribe = r.op == "events.subscribe";
                            let result = service.external(source.as_deref().unwrap(), r).await;
                            if subscribe {
                                if let Ok(v) = &result { cursor = v["next_seq"].as_i64(); }
                            }
                            result
                        };
                        (rid, result)
                    }
                    Err(e) => (String::new(), Err(ApiError::invalid(e))),
                };
                let line = format!("{}\n", response(&rid, result));
                if !matches!(tokio::time::timeout(Duration::from_secs(5), write.write_all(line.as_bytes())).await, Ok(Ok(()))) { break; }
                if source.is_none() { break; }
            },
            _ = interval.tick(), if cursor.is_some() => {
                match service.call(source.as_deref(), "events.list", json!({"after_seq": cursor})).await {
                    Ok(v) => {
                        for e in v["events"].as_array().unwrap() {
                            let line = format!("{e}\n");
                            if !matches!(tokio::time::timeout(Duration::from_secs(5), write.write_all(line.as_bytes())).await, Ok(Ok(()))) { return; }
                        }
                        cursor = v["next_seq"].as_i64();
                    }
                    Err(e) => {
                        let line = format!("{}\n", response("", Err(e)));
                        let _ = tokio::time::timeout(Duration::from_secs(5), write.write_all(line.as_bytes())).await;
                        cursor = None;
                    }
                }
            },
            _ = tokio::time::sleep_until(auth_deadline), if source.is_none() => break,
        }
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use futures_util::{SinkExt, StreamExt};
    use tokio_tungstenite::tungstenite::client::IntoClientRequest;

    #[tokio::test]
    async fn three_transports_share_contract_and_replay_events() {
        let service = Service::start(std::path::Path::new(":memory:"), None).unwrap();
        let credentials = service
            .call(None, "sources.create", json!({"id":"test"}))
            .await
            .unwrap();
        let token = credentials["token"].as_str().unwrap();
        let dir = std::env::temp_dir().join(format!("nt-{}", &id()[..8]));
        std::fs::create_dir(&dir).unwrap();
        let path = dir.join("s");
        let (ready, received) = tokio::sync::oneshot::channel();
        let server = tokio::spawn(start(service.clone(), 0, path.clone(), ready));
        let port = received.await.unwrap();
        let url = format!("http://127.0.0.1:{port}");
        let client = reqwest::Client::new();
        assert_eq!(
            client
                .get(format!("{url}/v1/notifications"))
                .send()
                .await
                .unwrap()
                .status(),
            StatusCode::UNAUTHORIZED
        );
        assert_eq!(
            client
                .get(format!("{url}/v1/notifications"))
                .bearer_auth(token)
                .header("Origin", "https://example.com")
                .send()
                .await
                .unwrap()
                .status(),
            StatusCode::UNAUTHORIZED
        );
        let payload =
            json!({"client_message_id":"same","title":"contract","body":"line one\nline two"});
        let accepted: Value = client
            .post(format!("{url}/v1/notifications"))
            .bearer_auth(token)
            .json(&payload)
            .send()
            .await
            .unwrap()
            .json()
            .await
            .unwrap();
        assert_eq!(accepted["accepted"], true);
        let oversized = client
            .post(format!("{url}/v1/notifications"))
            .bearer_auth(token)
            .header("content-type", "application/json")
            .body("x".repeat(MAX_FRAME + 1))
            .send()
            .await
            .unwrap();
        assert_eq!(oversized.status(), StatusCode::PAYLOAD_TOO_LARGE);
        let mut request = format!("ws://127.0.0.1:{port}/v1/ws")
            .into_client_request()
            .unwrap();
        request
            .headers_mut()
            .insert("authorization", format!("Bearer {token}").parse().unwrap());
        let (mut ws, _) = tokio_tungstenite::connect_async(request).await.unwrap();
        ws.send(tokio_tungstenite::tungstenite::Message::Text(
            json!({"v":1,"request_id":"ws","op":"notification.create","data":payload})
                .to_string()
                .into(),
        ))
        .await
        .unwrap();
        let reply: Value =
            serde_json::from_str(ws.next().await.unwrap().unwrap().to_text().unwrap()).unwrap();
        assert_eq!(
            reply["data"]["notification_id"],
            accepted["notification_id"]
        );
        assert_eq!(reply["data"]["duplicate"], true);
        let unix = tokio::net::UnixStream::connect(&path).await.unwrap();
        let (read, mut write) = unix.into_split();
        let mut lines = BufReader::new(read).lines();
        // Coalesced writes plus an intentionally split frame verify stream framing.
        let auth_line = format!(
            "{}\n",
            json!({"v":1,"request_id":"auth","op":"auth","data":{"token":token}})
        );
        let create_line = format!(
            "{}\n",
            json!({"v":1,"request_id":"unix","op":"notification.create","data":payload})
        );
        write
            .write_all(format!("{auth_line}{}", &create_line[..10]).as_bytes())
            .await
            .unwrap();
        write
            .write_all(&create_line.as_bytes()[10..])
            .await
            .unwrap();
        let auth_reply: Value =
            serde_json::from_str(&lines.next_line().await.unwrap().unwrap()).unwrap();
        assert_eq!(auth_reply["ok"], true);
        let unix_reply: Value =
            serde_json::from_str(&lines.next_line().await.unwrap().unwrap()).unwrap();
        assert_eq!(
            unix_reply["data"]["notification_id"],
            accepted["notification_id"]
        );
        ws.send(tokio_tungstenite::tungstenite::Message::Text(
            json!({"v":1,"request_id":"sub","op":"events.subscribe","data":{"after_seq":0}})
                .to_string()
                .into(),
        ))
        .await
        .unwrap();
        let initial: Value =
            serde_json::from_str(ws.next().await.unwrap().unwrap().to_text().unwrap()).unwrap();
        let seq = initial["data"]["next_seq"].as_i64().unwrap();
        assert!(seq > 0);
        client
            .post(format!("{url}/v1/notifications"))
            .bearer_auth(token)
            .json(&json!({"client_message_id":"second","title":"new"}))
            .send()
            .await
            .unwrap();
        let event = tokio::time::timeout(Duration::from_secs(3), ws.next())
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        let event: Value = serde_json::from_str(event.to_text().unwrap()).unwrap();
        assert_eq!(event["kind"], "event");
        assert!(event["seq"].as_i64().unwrap() > seq);
        let replay: Value = client
            .get(format!("{url}/v1/events?after_seq={seq}"))
            .bearer_auth(token)
            .send()
            .await
            .unwrap()
            .json()
            .await
            .unwrap();
        assert_eq!(replay["events"][0]["event_id"], event["event_id"]);
        let list: Value = client
            .get(format!("{url}/v1/notifications"))
            .bearer_auth(token)
            .send()
            .await
            .unwrap()
            .json()
            .await
            .unwrap();
        assert_eq!(list["total"], 2);
        server.abort();
        drop(ws);
        drop(write);
        drop(lines);
        let _ = std::fs::remove_file(path);
        let _ = std::fs::remove_dir(dir);
    }

    #[tokio::test]
    async fn unix_rejects_non_socket_path() {
        let path = std::env::temp_dir().join(format!("nt-{}", id()));
        std::fs::write(&path, "keep").unwrap();
        assert!(bind_unix(&path).is_err());
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "keep");
        std::fs::remove_file(path).unwrap();
    }
}
