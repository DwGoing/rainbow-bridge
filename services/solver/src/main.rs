use anyhow::{Context, Result, anyhow};
use chain_adapters::{ChainAdapter, ChainKind, EvmAdapter, SuiAdapter};
use solver::{build_proposal, build_settlement_action};
use std::env;
use std::fs::OpenOptions;
use std::io::Write;
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};
use types::{IntentSubmissionRef, IntentSubmittedEvent};

fn load_intent_event() -> Result<IntentSubmittedEvent> {
    let raw =
        env::var("SOLVER_INTENT_EVENT_JSON").context("missing SOLVER_INTENT_EVENT_JSON input")?;
    let event: IntentSubmittedEvent =
        serde_json::from_str(&raw).context("invalid SOLVER_INTENT_EVENT_JSON")?;
    Ok(event)
}

fn load_polled_intent_refs() -> Result<Vec<IntentSubmissionRef>> {
    let raw = env::var("SOLVER_POLLED_INTENT_REFS_JSON")
        .context("missing SOLVER_POLLED_INTENT_REFS_JSON input")?;
    let refs: Vec<IntentSubmissionRef> =
        serde_json::from_str(&raw).context("invalid SOLVER_POLLED_INTENT_REFS_JSON")?;
    Ok(refs)
}

fn load_polled_intent_events() -> Result<Vec<IntentSubmittedEvent>> {
    let raw = env::var("SOLVER_POLLED_INTENT_EVENTS_JSON")
        .context("missing SOLVER_POLLED_INTENT_EVENTS_JSON input")?;
    let events: Vec<IntentSubmittedEvent> =
        serde_json::from_str(&raw).context("invalid SOLVER_POLLED_INTENT_EVENTS_JSON")?;
    Ok(events)
}

fn build_adapter_from_env(prefix: &str) -> Result<Box<dyn ChainAdapter>> {
    let kind = env::var(format!("{prefix}_CHAIN_KIND")).unwrap_or_else(|_| "evm".to_string());
    let rpc = env::var(format!("{prefix}_RPC_URL"))
        .with_context(|| format!("missing {prefix}_RPC_URL for selected chain"))?;

    match kind.as_str() {
        "evm" => {
            let endpoint_address = env::var(format!("{prefix}_ENDPOINT_ADDRESS")).ok();
            if let Some(addr) = endpoint_address {
                let parsed = addr
                    .parse()
                    .with_context(|| format!("invalid {prefix}_ENDPOINT_ADDRESS"))?;
                Ok(Box::new(EvmAdapter::new_with_endpoint(rpc, parsed)))
            } else {
                Ok(Box::new(EvmAdapter::new(rpc)))
            }
        }
        "sui" => {
            let package_id = env::var(format!("{prefix}_PACKAGE_ID"))
                .ok()
                .or_else(|| env::var(format!("{prefix}_ENDPOINT_ADDRESS")).ok());
            let module =
                env::var(format!("{prefix}_MODULE")).unwrap_or_else(|_| "bridge".to_string());
            Ok(Box::new(SuiAdapter::new_with_module(
                rpc, package_id, module,
            )))
        }
        _ => Err(anyhow!(
            "unsupported {prefix}_CHAIN_KIND '{kind}', expected 'evm' or 'sui'"
        )),
    }
}

fn chain_kind_from_env(prefix: &str) -> String {
    env::var(format!("{prefix}_CHAIN_KIND")).unwrap_or_else(|_| "evm".to_string())
}

fn skip_rpc(prefix: &str) -> bool {
    env::var(format!("{prefix}_SKIP_RPC"))
        .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
        .unwrap_or(false)
}

fn use_chain_polling() -> bool {
    env::var("SOLVER_USE_CHAIN_POLLING")
        .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
        .unwrap_or(false)
}

fn enrich_polled_intents() -> bool {
    env::var("SOLVER_ENRICH_INTENTS")
        .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
        .unwrap_or(false)
}

fn now_unix() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn append_flow_event(kind: &str, intent_hash: &str, payload: serde_json::Value) -> Result<()> {
    let path =
        env::var("FLOW_EVENT_LOG_PATH").unwrap_or_else(|_| "data/flow-events.jsonl".to_string());
    if let Some(parent) = Path::new(&path).parent() {
        std::fs::create_dir_all(parent).with_context(|| {
            format!("failed to create flow log directory '{}'", parent.display())
        })?;
    }
    let mut file = OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)
        .with_context(|| format!("failed to open FLOW_EVENT_LOG_PATH '{path}'"))?;
    let line = serde_json::json!({
        "kind": kind,
        "intent_hash": intent_hash,
        "timestamp": now_unix(),
        "source": "solver",
        "payload": payload
    });
    writeln!(file, "{}", serde_json::to_string(&line)?)
        .with_context(|| format!("failed to append flow event to '{path}'"))?;
    Ok(())
}

fn try_append_flow_event(kind: &str, intent_hash: &str, payload: serde_json::Value) {
    if let Err(err) = append_flow_event(kind, intent_hash, payload) {
        eprintln!("warn: failed to append flow event ({kind}): {err}");
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    let (src_kind, src_block, src_adapter) = if skip_rpc("SOLVER_SRC") {
        (chain_kind_from_env("SOLVER_SRC"), 0, None)
    } else {
        let adapter = build_adapter_from_env("SOLVER_SRC")?;
        let kind = match adapter.kind() {
            ChainKind::Evm => "evm".to_string(),
            ChainKind::Sui => "sui".to_string(),
        };
        let block = adapter.get_block_number().await?;
        (kind, block, Some(adapter))
    };
    let (dst_kind, dst_block) = if skip_rpc("SOLVER_DST") {
        (chain_kind_from_env("SOLVER_DST"), 0)
    } else {
        let adapter = build_adapter_from_env("SOLVER_DST")?;
        let kind = match adapter.kind() {
            ChainKind::Evm => "evm".to_string(),
            ChainKind::Sui => "sui".to_string(),
        };
        let block = adapter.get_block_number().await?;
        (kind, block)
    };

    if use_chain_polling() {
        let from_block: u64 = env::var("SOLVER_FROM_BLOCK")
            .unwrap_or_else(|_| "0".to_string())
            .parse()
            .context("invalid SOLVER_FROM_BLOCK")?;
        let to_block: u64 = env::var("SOLVER_TO_BLOCK")
            .unwrap_or_else(|_| src_block.to_string())
            .parse()
            .context("invalid SOLVER_TO_BLOCK")?;

        if enrich_polled_intents() {
            let events = if let Some(src) = src_adapter.as_ref() {
                src.fetch_intent_events(from_block, to_block).await?
            } else {
                load_polled_intent_events()?
            };
            for event in &events {
                try_append_flow_event(
                    "intent_submitted",
                    &event.intent.intent_hash,
                    serde_json::to_value(event).unwrap_or_else(|_| serde_json::json!({})),
                );
            }
            println!(
                "{}",
                serde_json::to_string_pretty(&serde_json::json!({
                    "source_chain_kind": src_kind,
                    "destination_chain_kind": dst_kind,
                    "source_block_number": src_block,
                    "destination_block_number": dst_block,
                    "intent_submitted_events": events
                }))
                .context("failed to encode polled intent events")?
            );
        } else {
            let refs = if let Some(src) = src_adapter.as_ref() {
                src.fetch_intent_submissions(from_block, to_block).await?
            } else {
                load_polled_intent_refs()?
            };
            for r in &refs {
                try_append_flow_event(
                    "intent_submission_ref",
                    &r.intent_hash,
                    serde_json::to_value(r).unwrap_or_else(|_| serde_json::json!({})),
                );
            }
            println!(
                "{}",
                serde_json::to_string_pretty(&serde_json::json!({
                    "source_chain_kind": src_kind,
                    "destination_chain_kind": dst_kind,
                    "source_block_number": src_block,
                    "destination_block_number": dst_block,
                    "intent_submission_refs": refs
                }))
                .context("failed to encode polled intent submissions")?
            );
        }

        return Ok(());
    }

    let event = load_intent_event()?;
    let solver = env::var("SOLVER_ADDRESS").unwrap_or_else(|_| "solver-local".to_string());
    let validator = env::var("VALIDATOR_ADDRESS").unwrap_or_else(|_| "validator-local".to_string());
    let amount_out = event.intent.min_dst_amount;

    let proposal = build_proposal(&event, &solver, &validator, amount_out)?;
    try_append_flow_event(
        "intent_submitted",
        &event.intent.intent_hash,
        serde_json::to_value(&event).unwrap_or_else(|_| serde_json::json!({})),
    );
    try_append_flow_event(
        "settlement_proposed",
        &proposal.intent_hash,
        serde_json::to_value(&proposal).unwrap_or_else(|_| serde_json::json!({})),
    );
    let src_action_target = env::var("SOLVER_SRC_ENDPOINT_ADDRESS")
        .ok()
        .or_else(|| env::var("SOLVER_SRC_PACKAGE_ID").ok());
    let src_state_object_id = env::var("SOLVER_SRC_STATE_OBJECT_ID").ok();
    let settlement_action = build_settlement_action(
        &src_kind,
        src_action_target.as_deref(),
        src_state_object_id.as_deref(),
        &proposal,
    )?;
    let payload = serde_json::json!({
        "source_chain_kind": src_kind,
        "destination_chain_kind": dst_kind,
        "source_block_number": src_block,
        "destination_block_number": dst_block,
        "proposal": proposal,
        "recommended_settlement_action": settlement_action
    });
    println!(
        "{}",
        serde_json::to_string_pretty(&payload).context("failed to encode proposal payload")?
    );

    Ok(())
}
