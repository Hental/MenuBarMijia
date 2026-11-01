use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::net::{TcpStream, ToSocketAddrs};
use std::time::{Duration, Instant};
use tungstenite::{client_tls, stream::MaybeTlsStream, Message, WebSocket};

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HaSnapshot {
    areas: Value,
    devices: Value,
    entities: Value,
    states: Value,
}

#[derive(Deserialize)]
pub struct HaServiceCall {
    domain: String,
    service: String,
    entity_id: String,
    data: serde_json::Map<String, Value>,
}

fn endpoint(base_url: &str, token: &str) -> Result<String, String> {
    if token.trim().is_empty() {
        return Err("Home Assistant token is required".into());
    }
    let mut url = reqwest::Url::parse(base_url.trim()).map_err(|_| "Invalid Home Assistant URL")?;
    if url.query().is_some() || url.fragment().is_some() || url.path() != "/" {
        return Err("Home Assistant URL must be an origin".into());
    }
    let origin =
        crate::url_origin(&url).ok_or("Home Assistant requires an HTTP or HTTPS origin")?;
    if !crate::allowed_origins_snapshot()?.contains(&origin) {
        return Err("Home Assistant endpoint has not been approved".into());
    }
    let scheme = if url.scheme() == "https" { "wss" } else { "ws" };
    url.set_scheme(scheme)
        .map_err(|_| "Invalid Home Assistant URL")?;
    url.set_path("/api/websocket");
    Ok(url.to_string())
}

type Socket = WebSocket<MaybeTlsStream<TcpStream>>;

fn receive(socket: &mut Socket) -> Result<Value, String> {
    let deadline = Instant::now() + Duration::from_secs(15);
    for _ in 0..64 {
        if Instant::now() >= deadline {
            return Err("Home Assistant read timed out".into());
        }
        match socket
            .read()
            .map_err(|_| "Home Assistant connection failed")?
        {
            Message::Text(text) => {
                return serde_json::from_str(&text)
                    .map_err(|_| "Invalid Home Assistant response".into())
            }
            Message::Close(_) => return Err("Home Assistant disconnected".into()),
            _ => {}
        }
    }
    Err("Home Assistant sent too many control frames".into())
}

fn send(socket: &mut Socket, packet: Value) -> Result<(), String> {
    socket
        .send(Message::Text(packet.to_string().into()))
        .map_err(|_| "Home Assistant send failed".into())
}

fn authenticated(base_url: &str, token: &str) -> Result<Socket, String> {
    let url = endpoint(base_url, token)?;
    let parsed = reqwest::Url::parse(&url).map_err(|_| "Invalid Home Assistant URL")?;
    let host = parsed
        .host_str()
        .ok_or("Invalid Home Assistant host")?
        .trim_start_matches('[')
        .trim_end_matches(']');
    let port = parsed
        .port_or_known_default()
        .ok_or("Invalid Home Assistant port")?;
    let addresses = (host, port)
        .to_socket_addrs()
        .map_err(|_| "Home Assistant address lookup failed")?;
    let stream = addresses
        .filter_map(|address| TcpStream::connect_timeout(&address, Duration::from_secs(5)).ok())
        .next()
        .ok_or("Home Assistant connection failed")?;
    stream
        .set_read_timeout(Some(Duration::from_secs(10)))
        .map_err(|_| "Home Assistant socket setup failed")?;
    stream
        .set_write_timeout(Some(Duration::from_secs(10)))
        .map_err(|_| "Home Assistant socket setup failed")?;
    let (mut socket, _) =
        client_tls(url.as_str(), stream).map_err(|_| "Home Assistant handshake failed")?;
    if receive(&mut socket)?["type"] != "auth_required" {
        return Err("Home Assistant authentication handshake failed".into());
    }
    send(&mut socket, json!({"type":"auth", "access_token": token}))?;
    if receive(&mut socket)?["type"] != "auth_ok" {
        return Err("Home Assistant authentication rejected".into());
    }
    Ok(socket)
}

fn request(socket: &mut Socket, id: u32, mut packet: Value) -> Result<Value, String> {
    packet["id"] = json!(id);
    send(socket, packet)?;
    let deadline = Instant::now() + Duration::from_secs(15);
    for _ in 0..64 {
        if Instant::now() >= deadline {
            return Err("Home Assistant request timed out".into());
        }
        let response = receive(socket)?;
        if response["id"] != id {
            continue;
        }
        if response["type"] != "result" || response["success"] != true {
            return Err("Home Assistant request failed".into());
        }
        return Ok(response["result"].clone());
    }
    Err("Home Assistant response did not match request id".into())
}

fn validate_call(command: &HaServiceCall) -> Result<(), String> {
    let allowed: &[(&str, &[&str])] = &[
        ("light", &["turn_on", "turn_off"]),
        (
            "climate",
            &["set_hvac_mode", "set_temperature", "set_fan_mode"],
        ),
        (
            "fan",
            &[
                "turn_on",
                "turn_off",
                "set_percentage",
                "set_preset_mode",
                "oscillate",
            ],
        ),
        ("switch", &["turn_on", "turn_off"]),
        ("camera", &["turn_on", "turn_off"]),
        ("select", &["select_option"]),
        ("vacuum", &["start", "pause", "return_to_base"]),
        ("scene", &["turn_on"]),
        ("script", &["turn_on"]),
    ];
    if !allowed.iter().any(|(domain, services)| {
        *domain == command.domain && services.contains(&command.service.as_str())
    }) || !command
        .entity_id
        .starts_with(&format!("{}.", command.domain))
        || command.entity_id.len() <= command.domain.len() + 1
        || !command.entity_id.chars().all(|character| {
            character.is_ascii_alphanumeric() || character == '_' || character == '.'
        })
    {
        return Err("Home Assistant service is not allowed".into());
    }
    let keys: &[&str] = match (command.domain.as_str(), command.service.as_str()) {
        ("light", "turn_on") => &["brightness_pct", "color_temp_kelvin", "effect"],
        ("climate", "set_hvac_mode") => &["hvac_mode"],
        ("climate", "set_temperature") => &["temperature"],
        ("climate", "set_fan_mode") => &["fan_mode"],
        ("fan", "set_percentage") => &["percentage"],
        ("fan", "set_preset_mode") => &["preset_mode"],
        ("fan", "oscillate") => &["oscillating"],
        ("select", "select_option") => &["option"],
        _ => &[],
    };
    if command.data.keys().any(|key| !keys.contains(&key.as_str())) {
        return Err("Home Assistant service data is not allowed".into());
    }
    Ok(())
}

#[tauri::command]
pub async fn ha_snapshot(base_url: String, token: String) -> Result<HaSnapshot, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let mut socket = authenticated(&base_url, &token)?;
        let result = HaSnapshot {
            areas: request(&mut socket, 1, json!({"type":"config/area_registry/list"}))?,
            devices: request(
                &mut socket,
                2,
                json!({"type":"config/device_registry/list"}),
            )?,
            entities: request(
                &mut socket,
                3,
                json!({"type":"config/entity_registry/list"}),
            )?,
            states: request(&mut socket, 4, json!({"type":"get_states"}))?,
        };
        let _ = socket.close(None);
        Ok(result)
    })
    .await
    .map_err(|_| "Home Assistant worker failed".to_string())?
}

#[tauri::command]
pub async fn ha_execute(
    base_url: String,
    token: String,
    command: HaServiceCall,
) -> Result<(), String> {
    validate_call(&command)?;
    tauri::async_runtime::spawn_blocking(move || {
        let mut socket = authenticated(&base_url, &token)?;
        request(&mut socket, 1, json!({"type":"call_service", "domain":command.domain, "service":command.service, "target":{"entity_id":command.entity_id}, "service_data":command.data}))?;
        let _ = socket.close(None);
        Ok(())
    }).await.map_err(|_| "Home Assistant worker failed".to_string())?
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rejects_missing_tokens_and_non_http_origins() {
        assert!(endpoint("http://localhost:8123", "").is_err());
        assert!(endpoint("file:///tmp/ha", "example").is_err());
        assert!(endpoint("ws://localhost:8123", "example").is_err());
        assert!(endpoint("http://localhost:8123", "example").is_err());
    }
    #[test]
    fn restricts_service_commands_and_target_overrides() {
        let mut call = HaServiceCall {
            domain: "light".into(),
            service: "turn_on".into(),
            entity_id: "light.study".into(),
            data: Default::default(),
        };
        assert!(validate_call(&call).is_ok());
        call.service = "delete".into();
        assert!(validate_call(&call).is_err());
        call.service = "turn_on".into();
        call.data.insert("entity_id".into(), json!("all"));
        assert!(validate_call(&call).is_err());
    }

    #[test]
    fn controlled_websocket_auth_snapshot_and_service_smoke() {
        let _guard = crate::ORIGIN_TEST_LOCK.lock().unwrap();
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let base_url = format!("http://{}", listener.local_addr().unwrap());
        let origin = crate::normalize_extra_origin(&base_url).unwrap();
        crate::EXTRA_ALLOWED_ORIGINS
            .write()
            .unwrap()
            .insert(origin.clone());
        let fixture: Value =
            serde_json::from_str(include_str!("../../../Tests/Fixtures/ha_snapshot.json")).unwrap();
        let peer = std::thread::spawn(move || {
            let mut snapshots = 0;
            let mut services = 0;
            let mut handshakes = 0;
            for connection in 0..8 {
                let (stream, _) = listener.accept().unwrap();
                stream
                    .set_read_timeout(Some(Duration::from_secs(10)))
                    .unwrap();
                let mut socket = tungstenite::accept(stream).unwrap();
                socket
                    .send(Message::Text(
                        json!({"type":"auth_required","ha_version":"controlled-fixture"})
                            .to_string()
                            .into(),
                    ))
                    .unwrap();
                let auth: Value =
                    serde_json::from_str(socket.read().unwrap().to_text().unwrap()).unwrap();
                assert_eq!(auth["type"], "auth");
                assert_eq!(auth["access_token"], "controlled-native-token");
                handshakes += 1;
                if connection == 7 {
                    socket
                        .send(Message::Text(
                            json!({"type":"auth_invalid","message":"controlled-native-token"})
                                .to_string()
                                .into(),
                        ))
                        .unwrap();
                    continue;
                }
                socket
                    .send(Message::Text(json!({"type":"auth_ok"}).to_string().into()))
                    .unwrap();
                let requests = if connection < 5 { 4 } else { 1 };
                for index in 0..requests {
                    let packet: Value =
                        serde_json::from_str(socket.read().unwrap().to_text().unwrap()).unwrap();
                    let result = if connection < 5 {
                        let names = [
                            "config/area_registry/list",
                            "config/device_registry/list",
                            "config/entity_registry/list",
                            "get_states",
                        ];
                        assert_eq!(packet["type"], names[index]);
                        fixture[["areas", "devices", "entities", "states"][index]].clone()
                    } else {
                        assert_eq!(packet["type"], "call_service");
                        assert_eq!(packet["domain"], "light");
                        assert_eq!(packet["service"], "turn_off");
                        assert_eq!(packet["target"]["entity_id"], "light.study");
                        services += 1;
                        Value::Null
                    };
                    let response = if connection == 6 {
                        json!({"id":packet["id"],"type":"result","success":false,"error":{"message":"controlled-native-token"}})
                    } else {
                        json!({"id":packet["id"],"type":"result","success":true,"result":result})
                    };
                    socket
                        .send(Message::Text(response.to_string().into()))
                        .unwrap();
                }
                if connection < 5 {
                    snapshots += 1;
                }
            }
            (handshakes, snapshots, services)
        });
        let mut snapshot_ms = Vec::new();
        for _ in 0..5 {
            let start = std::time::Instant::now();
            let snapshot = tauri::async_runtime::block_on(ha_snapshot(
                base_url.clone(),
                "controlled-native-token".into(),
            ))
            .unwrap();
            let serialized = serde_json::to_string(&snapshot).unwrap();
            assert!(!serialized.contains("controlled-native-token"));
            assert_eq!(snapshot.areas.as_array().unwrap().len(), 1);
            assert_eq!(snapshot.states.as_array().unwrap().len(), 6);
            snapshot_ms.push(start.elapsed().as_secs_f64() * 1000.0);
        }
        for fail in [false, true] {
            let command = HaServiceCall {
                domain: "light".into(),
                service: "turn_off".into(),
                entity_id: "light.study".into(),
                data: Default::default(),
            };
            let result = tauri::async_runtime::block_on(ha_execute(
                base_url.clone(),
                "controlled-native-token".into(),
                command,
            ));
            assert_eq!(result.is_err(), fail);
            if let Err(error) = result {
                assert!(!error.contains("controlled-native-token"));
            }
        }
        let error =
            tauri::async_runtime::block_on(ha_snapshot(base_url, "controlled-native-token".into()))
                .err()
                .unwrap();
        assert_eq!(error, "Home Assistant authentication rejected");
        assert_eq!(peer.join().unwrap(), (8, 5, 2));
        crate::EXTRA_ALLOWED_ORIGINS
            .write()
            .unwrap()
            .remove(&origin);
        println!("HA_SOCKET_SMOKE handshakes=8 snapshots=5 service_success=1 service_failure=1 auth_rejection=1 secret_leaks=0 snapshot_ms={snapshot_ms:?}");
    }
}
