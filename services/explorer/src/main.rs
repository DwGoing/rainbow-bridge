use anyhow::{Context, Result};
use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::response::{Html, IntoResponse};
use axum::routing::get;
use axum::{Json, Router};
use serde::Serialize;
use serde_json::Value;
use std::collections::BTreeMap;
use std::env;
use std::fs::File;
use std::io::{BufRead, BufReader};
use std::net::SocketAddr;
use std::sync::Arc;

#[derive(Clone)]
struct AppState {
    event_log_path: String,
}

#[derive(Debug, Clone, Serialize)]
struct ExplorerEvent {
    kind: String,
    intent_hash: String,
    timestamp: u64,
    source: Option<String>,
    payload: Value,
}

#[derive(Debug, Clone, Serialize)]
struct FlowView {
    intent_hash: String,
    latest_timestamp: u64,
    event_count: usize,
    intent_submitted: Vec<Value>,
    settlement_proposed: Vec<Value>,
    validator_decisions: Vec<Value>,
    execution_results: Vec<Value>,
    timeline: Vec<ExplorerEvent>,
}

#[derive(Debug, Clone, Serialize)]
struct FlowSummary {
    intent_hash: String,
    latest_timestamp: u64,
    event_count: usize,
    status_hint: String,
}

fn load_events(path: &str) -> Result<Vec<ExplorerEvent>> {
    let file = match File::open(path) {
        Ok(f) => f,
        Err(_) => return Ok(Vec::new()),
    };
    let reader = BufReader::new(file);
    let mut events = Vec::new();
    for line in reader.lines() {
        let raw = match line {
            Ok(v) => v,
            Err(_) => continue,
        };
        if raw.trim().is_empty() {
            continue;
        }
        let v: Value = match serde_json::from_str(&raw) {
            Ok(v) => v,
            Err(_) => continue,
        };
        let kind = match v.get("kind").and_then(|x| x.as_str()) {
            Some(x) => x.to_string(),
            None => continue,
        };
        let intent_hash = match v.get("intent_hash").and_then(|x| x.as_str()) {
            Some(x) => x.to_string(),
            None => continue,
        };
        let timestamp = v.get("timestamp").and_then(|x| x.as_u64()).unwrap_or(0);
        let source = v
            .get("source")
            .and_then(|x| x.as_str())
            .map(ToString::to_string);
        let payload = v.get("payload").cloned().unwrap_or(Value::Null);
        events.push(ExplorerEvent {
            kind,
            intent_hash,
            timestamp,
            source,
            payload,
        });
    }
    events.sort_by_key(|e| e.timestamp);
    Ok(events)
}

fn build_flows(events: Vec<ExplorerEvent>) -> BTreeMap<String, FlowView> {
    let mut map = BTreeMap::<String, FlowView>::new();
    for event in events {
        let key = event.intent_hash.clone();
        let entry = map.entry(key.clone()).or_insert_with(|| FlowView {
            intent_hash: key.clone(),
            latest_timestamp: 0,
            event_count: 0,
            intent_submitted: Vec::new(),
            settlement_proposed: Vec::new(),
            validator_decisions: Vec::new(),
            execution_results: Vec::new(),
            timeline: Vec::new(),
        });

        entry.latest_timestamp = entry.latest_timestamp.max(event.timestamp);
        entry.event_count += 1;
        match event.kind.as_str() {
            "intent_submitted" | "intent_submission_ref" => {
                entry.intent_submitted.push(event.payload.clone());
            }
            "settlement_proposed" => entry.settlement_proposed.push(event.payload.clone()),
            "validator_decision" => entry.validator_decisions.push(event.payload.clone()),
            "execution_result" => entry.execution_results.push(event.payload.clone()),
            _ => {}
        }
        entry.timeline.push(event);
    }
    map
}

fn status_hint(flow: &FlowView) -> String {
    if let Some(last) = flow.execution_results.last() {
        if let Some(s) = last.get("status").and_then(|x| x.as_str()) {
            return s.to_string();
        }
    }
    if let Some(last) = flow.validator_decisions.last() {
        if let Some(action) = last.get("action").and_then(|x| x.as_str()) {
            return format!("validator:{action}");
        }
    }
    if !flow.settlement_proposed.is_empty() {
        return "settlement_proposed".to_string();
    }
    if !flow.intent_submitted.is_empty() {
        return "intent_submitted".to_string();
    }
    "unknown".to_string()
}

async fn health() -> Json<Value> {
    Json(serde_json::json!({ "ok": true }))
}

async fn flows(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    match load_events(&state.event_log_path) {
        Ok(events) => {
            let flows = build_flows(events);
            let mut out = Vec::<FlowSummary>::new();
            for flow in flows.values() {
                out.push(FlowSummary {
                    intent_hash: flow.intent_hash.clone(),
                    latest_timestamp: flow.latest_timestamp,
                    event_count: flow.event_count,
                    status_hint: status_hint(flow),
                });
            }
            out.sort_by(|a, b| b.latest_timestamp.cmp(&a.latest_timestamp));
            Json(out).into_response()
        }
        Err(err) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(serde_json::json!({ "error": err.to_string() })),
        )
            .into_response(),
    }
}

async fn flow_detail(
    Path(intent_hash): Path<String>,
    State(state): State<Arc<AppState>>,
) -> impl IntoResponse {
    match load_events(&state.event_log_path) {
        Ok(events) => {
            let flows = build_flows(events);
            if let Some(flow) = flows.get(&intent_hash) {
                Json(flow).into_response()
            } else {
                (
                    StatusCode::NOT_FOUND,
                    Json(serde_json::json!({ "error": "flow not found" })),
                )
                    .into_response()
            }
        }
        Err(err) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(serde_json::json!({ "error": err.to_string() })),
        )
            .into_response(),
    }
}

async fn events(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    match load_events(&state.event_log_path) {
        Ok(events) => Json(events).into_response(),
        Err(err) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(serde_json::json!({ "error": err.to_string() })),
        )
            .into_response(),
    }
}

async fn index(State(state): State<Arc<AppState>>) -> Html<String> {
    let html = format!(
        r#"<!doctype html>
<html>
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Rainbow Bridge Explorer</title>
  <style>
    :root {{
      --bg: #0f1220;
      --card: #171b2e;
      --accent: #00d2a8;
      --text: #edf0ff;
      --muted: #9aa3c7;
      --border: #283157;
    }}
    body {{
      margin: 0;
      background: radial-gradient(circle at 20% -10%, #263060 0%, var(--bg) 55%);
      color: var(--text);
      font-family: "IBM Plex Sans", "Segoe UI", sans-serif;
    }}
    .wrap {{ max-width: 1200px; margin: 0 auto; padding: 20px; }}
    .head {{ display:flex; justify-content: space-between; align-items: center; }}
    .title {{ font-size: 28px; font-weight: 700; }}
    .meta {{ color: var(--muted); font-size: 13px; }}
    .grid {{ display:grid; grid-template-columns: 1fr 1fr; gap: 16px; margin-top: 16px; }}
    .card {{
      background: linear-gradient(180deg, #1b2140, var(--card));
      border: 1px solid var(--border);
      border-radius: 14px;
      padding: 14px;
      min-height: 420px;
    }}
    table {{ width:100%; border-collapse: collapse; font-size: 13px; }}
    th, td {{ border-bottom: 1px solid var(--border); padding: 8px; text-align: left; }}
    tr:hover {{ background: #1f274a; cursor: pointer; }}
    pre {{
      background: #0d1122;
      border: 1px solid var(--border);
      border-radius: 10px;
      padding: 12px;
      overflow: auto;
      max-height: 560px;
      color: #cfe3ff;
      font-size: 12px;
    }}
    .badge {{ color: #042a22; background: var(--accent); padding: 2px 8px; border-radius: 999px; font-weight: 700; }}
    @media (max-width: 900px) {{ .grid {{ grid-template-columns: 1fr; }} }}
  </style>
</head>
<body>
  <div class="wrap">
    <div class="head">
      <div>
        <div class="title">Rainbow Bridge Explorer</div>
        <div class="meta">event log: {}</div>
      </div>
      <button id="refresh">Refresh</button>
    </div>
    <div class="grid">
      <div class="card">
        <h3>Flows</h3>
        <table id="flowsTable">
          <thead><tr><th>intent</th><th>status</th><th>events</th><th>updated</th></tr></thead>
          <tbody></tbody>
        </table>
      </div>
      <div class="card">
        <h3>Flow Detail</h3>
        <div id="hint" class="meta">Select a flow from the table.</div>
        <pre id="detail">{{}}</pre>
      </div>
    </div>
  </div>
  <script>
    async function loadFlows() {{
      const resp = await fetch('/api/flows');
      const data = await resp.json();
      const body = document.querySelector('#flowsTable tbody');
      body.innerHTML = '';
      for (const row of data) {{
        const tr = document.createElement('tr');
        tr.innerHTML = `
          <td><code>${{row.intent_hash.slice(0, 14)}}...</code></td>
          <td><span class="badge">${{row.status_hint}}</span></td>
          <td>${{row.event_count}}</td>
          <td>${{new Date(row.latest_timestamp * 1000).toLocaleString()}}</td>
        `;
        tr.onclick = () => loadDetail(row.intent_hash);
        body.appendChild(tr);
      }}
    }}

    async function loadDetail(intentHash) {{
      const resp = await fetch(`/api/flows/${{intentHash}}`);
      const data = await resp.json();
      document.querySelector('#hint').textContent = intentHash;
      document.querySelector('#detail').textContent = JSON.stringify(data, null, 2);
    }}

    document.querySelector('#refresh').onclick = loadFlows;
    loadFlows();
  </script>
</body>
</html>"#,
        state.event_log_path
    );
    Html(html)
}

#[tokio::main]
async fn main() -> Result<()> {
    let bind = env::var("EXPLORER_BIND").unwrap_or_else(|_| "127.0.0.1:8080".to_string());
    let event_log_path =
        env::var("FLOW_EVENT_LOG_PATH").unwrap_or_else(|_| "data/flow-events.jsonl".to_string());

    let state = Arc::new(AppState { event_log_path });
    let app = Router::new()
        .route("/", get(index))
        .route("/api/health", get(health))
        .route("/api/events", get(events))
        .route("/api/flows", get(flows))
        .route("/api/flows/:intent_hash", get(flow_detail))
        .with_state(state);

    let addr: SocketAddr = bind
        .parse()
        .with_context(|| format!("invalid EXPLORER_BIND '{bind}'"))?;
    let listener = tokio::net::TcpListener::bind(addr).await?;
    println!("explorer listening on http://{}", bind);
    axum::serve(listener, app).await?;
    Ok(())
}
