use futures_util::{SinkExt, StreamExt};
use serde::{Deserialize, Serialize};
use std::net::SocketAddr;
use std::sync::Arc;
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::broadcast;
use tokio_tungstenite::tungstenite::handshake::server::{Request, Response};
use tokio_tungstenite::tungstenite::Message;

use crate::config::BenchmarkConfig;
use crate::demuxer::StreamBroadcaster;
use crate::telemetry::{FpsMetricsPayload, SharedTelemetry, StreamReport};

#[derive(Debug, Deserialize)]
#[serde(tag = "type")]
enum ClientMessage {
    #[serde(rename = "tick_fps")]
    TickFps {
        #[serde(rename = "streamFpsList")]
        stream_fps_list: Vec<u32>,
        #[serde(rename = "streamReports", default)]
        stream_reports: Option<Vec<StreamReport>>,
    },
    #[serde(rename = "log")]
    Log {
        level: String,
        message: String,
    },
}

#[derive(Debug, Serialize)]
struct InitPayload<'a> {
    #[serde(rename = "streamCount")]
    stream_count: usize,
    framework: &'a str,
    #[serde(rename = "hardwareMode")]
    hardware_mode: &'a str,
    #[serde(rename = "targetFps")]
    target_fps: u32,
    #[serde(rename = "windowDurationSeconds")]
    window_duration_seconds: u32,
    #[serde(rename = "machineId")]
    machine_id: &'a str,
    #[serde(rename = "logPath")]
    log_path: String,
}

#[derive(Debug, Serialize)]
struct InitMessage<'a> {
    #[serde(rename = "type")]
    msg_type: &'a str,
    data: InitPayload<'a>,
}

#[derive(Debug, Serialize)]
struct TelemetryTickData<'a> {
    payload: &'a FpsMetricsPayload,
    #[serde(rename = "currentWindowSec")]
    current_window_sec: u32,
    #[serde(rename = "streamFpsList")]
    stream_fps_list: &'a [u32],
}

#[derive(Debug, Serialize)]
struct TelemetryTickMessage<'a> {
    #[serde(rename = "type")]
    msg_type: &'a str,
    data: TelemetryTickData<'a>,
}

pub struct VideoWebSocketServer {
    config: BenchmarkConfig,
    broadcasters: Vec<StreamBroadcaster>,
    telemetry: SharedTelemetry,
    control_tx: broadcast::Sender<String>,
}

impl VideoWebSocketServer {
    pub fn new(
        config: BenchmarkConfig,
        broadcasters: Vec<StreamBroadcaster>,
        telemetry: SharedTelemetry,
    ) -> Self {
        let (control_tx, _) = broadcast::channel(128);
        Self {
            config,
            broadcasters,
            telemetry,
            control_tx,
        }
    }

    pub async fn run(self: Arc<Self>) -> Result<(), Box<dyn std::error::Error>> {
        let addr = SocketAddr::from(([127, 0, 0, 1], self.config.ws_port));
        let listener = TcpListener::bind(&addr).await?;
        println!("[WSS] WebSocket server listening on ws://{}", addr);

        loop {
            match listener.accept().await {
                Ok((stream, remote_addr)) => {
                    let server = self.clone();
                    tokio::spawn(async move {
                        if let Err(e) = server.handle_connection(stream, remote_addr).await {
                            eprintln!("[WSS] Connection error from {}: {}", remote_addr, e);
                        }
                    });
                }
                Err(e) => {
                    eprintln!("[WSS] Accept error: {}", e);
                }
            }
        }
    }

    async fn handle_connection(&self, stream: TcpStream, _remote_addr: SocketAddr) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        let mut req_path = String::new();

        let ws_stream = tokio_tungstenite::accept_hdr_async(stream, |req: &Request, res: Response| {
            req_path = req.uri().path().to_string();
            Ok(res)
        })
        .await?;

        if req_path == "/control" {
            self.handle_control(ws_stream).await?;
        } else if let Some(stream_id_str) = req_path.strip_prefix("/stream/") {
            if let Ok(stream_id) = stream_id_str.parse::<usize>() {
                if stream_id < self.broadcasters.len() {
                    self.handle_stream(stream_id, ws_stream).await?;
                } else {
                    eprintln!("[WSS] Requested invalid stream index: {}", stream_id);
                }
            }
        }

        Ok(())
    }

    async fn handle_stream(
        &self,
        stream_id: usize,
        mut ws_stream: tokio_tungstenite::WebSocketStream<TcpStream>,
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        let mut rx = self.broadcasters[stream_id].sender.subscribe();

        loop {
            tokio::select! {
                sample = rx.recv() => {
                    match sample {
                        Ok(data) => {
                            let msg = Message::Binary(data);
                            if let Err(_e) = ws_stream.send(msg).await {
                                // Client disconnected
                                break;
                            }
                        }
                        Err(broadcast::error::RecvError::Lagged(_skipped)) => {
                            // High load backpressure: skip frames to maintain latency
                            continue;
                        }
                        Err(broadcast::error::RecvError::Closed) => {
                            break;
                        }
                    }
                }
                client_msg = ws_stream.next() => {
                    match client_msg {
                        Some(Ok(Message::Close(_))) | None => break,
                        Some(Err(_)) => break,
                        _ => {}
                    }
                }
            }
        }

        Ok(())
    }

    async fn handle_control(
        &self,
        mut ws_stream: tokio_tungstenite::WebSocketStream<TcpStream>,
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        // Send init message
        let log_path = {
            let telem = self.telemetry.read().unwrap();
            telem.get_log_path()
        };

        let init_msg = InitMessage {
            msg_type: "init",
            data: InitPayload {
                stream_count: self.config.stream_count,
                framework: &self.config.framework,
                hardware_mode: &self.config.hardware_mode,
                target_fps: self.config.target_fps,
                window_duration_seconds: self.config.window_duration_seconds,
                machine_id: &self.config.machine_id,
                log_path,
            },
        };

        let init_json = serde_json::to_string(&init_msg)?;
        ws_stream.send(Message::Text(init_json.into())).await?;

        let mut control_rx = self.control_tx.subscribe();

        loop {
            tokio::select! {
                broadcast_msg = control_rx.recv() => {
                    if let Ok(msg_text) = broadcast_msg {
                        if let Err(_) = ws_stream.send(Message::Text(msg_text.into())).await {
                            break;
                        }
                    }
                }
                client_msg = ws_stream.next() => {
                    match client_msg {
                        Some(Ok(Message::Text(text))) => {
                            if let Ok(msg) = serde_json::from_str::<ClientMessage>(&text) {
                                match msg {
                                    ClientMessage::Log { level, message } => {
                                        println!("[Renderer {}] {}", level, message);
                                    }
                                    ClientMessage::TickFps { stream_fps_list, stream_reports } => {
                                        let (payload, current_sec) = {
                                            let mut telem = self.telemetry.write().unwrap();
                                            telem.record_tick(&stream_fps_list, stream_reports.as_deref())
                                        };

                                        let tick_msg = TelemetryTickMessage {
                                            msg_type: "telemetry_tick",
                                            data: TelemetryTickData {
                                                payload: &payload,
                                                current_window_sec: current_sec,
                                                stream_fps_list: &stream_fps_list,
                                            },
                                        };

                                        if let Ok(json) = serde_json::to_string(&tick_msg) {
                                            let _ = self.control_tx.send(json);
                                        }
                                    }
                                }
                            }
                        }
                        Some(Ok(Message::Close(_))) | None => break,
                        Some(Err(_)) => break,
                        _ => {}
                    }
                }
            }
        }

        Ok(())
    }
}
