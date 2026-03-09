use anyhow::{Context, Result, anyhow};
use chain_adapters::{ChainAdapter, EvmAdapter, SuiAdapter};
use solver::{build_proposal, build_settlement_action};
use std::env;
use std::fs::OpenOptions;
use std::io::Write;
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};
use tokio::time::{Duration, sleep};
use types::{IntentSubmissionRef, IntentSubmittedEvent};

#[derive(Debug, Clone, serde::Deserialize)]
struct ChainConfigInput {
    name: Option<String>,
    chain_kind: String,
    rpc_url: Option<String>,
    endpoint_address: Option<String>,
    package_id: Option<String>,
    state_object_id: Option<String>,
    module: Option<String>,
    skip_rpc: Option<bool>,
    chain_id: Option<u64>,
}

#[derive(Debug, Clone)]
struct ChainConfig {
    name: String,
    chain_kind: String,
    rpc_url: Option<String>,
    endpoint_address: Option<String>,
    package_id: Option<String>,
    state_object_id: Option<String>,
    module: String,
    skip_rpc: bool,
    chain_id: Option<u64>,
}

struct ChainRuntime {
    config: ChainConfig,
    block_number: u64,
    adapter: Option<Box<dyn ChainAdapter>>,
}

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

fn normalize_chain_config(_prefix: &str, idx: usize, input: ChainConfigInput) -> ChainConfig {
    let kind = input.chain_kind.to_lowercase();
    ChainConfig {
        name: input
            .name
            .unwrap_or_else(|| format!("{}-{}", kind, idx + 1)),
        chain_kind: kind,
        rpc_url: input.rpc_url,
        endpoint_address: input.endpoint_address,
        package_id: input.package_id,
        state_object_id: input.state_object_id,
        module: input.module.unwrap_or_else(|| "bridge".to_string()),
        skip_rpc: input.skip_rpc.unwrap_or(false),
        chain_id: input.chain_id,
    }
}

fn load_chain_configs(prefix: &str) -> Result<Vec<ChainConfig>> {
    let key = format!("{prefix}_CHAINS_JSON");
    let raw = env::var(&key).with_context(|| format!("missing {key}"))?;
    let parsed: Vec<ChainConfigInput> =
        serde_json::from_str(&raw).with_context(|| format!("invalid {key}"))?;
    if parsed.is_empty() {
        return Err(anyhow!("{key} cannot be empty"));
    }

    let mut out = Vec::with_capacity(parsed.len());
    for (idx, cfg) in parsed.into_iter().enumerate() {
        let normalized = normalize_chain_config(prefix, idx, cfg);
        if !normalized.skip_rpc && normalized.rpc_url.is_none() {
            return Err(anyhow!("{key}[{idx}] requires rpc_url when skip_rpc=false"));
        }
        out.push(normalized);
    }
    Ok(out)
}

fn build_adapter_from_config(cfg: &ChainConfig) -> Result<Box<dyn ChainAdapter>> {
    let rpc = cfg
        .rpc_url
        .clone()
        .ok_or_else(|| anyhow!("missing rpc_url for chain {}", cfg.name))?;
    match cfg.chain_kind.as_str() {
        "evm" => {
            if let Some(addr) = cfg.endpoint_address.as_deref() {
                let parsed = addr
                    .parse()
                    .with_context(|| format!("invalid endpoint_address for {}", cfg.name))?;
                Ok(Box::new(EvmAdapter::new_with_endpoint(rpc, parsed)))
            } else {
                Ok(Box::new(EvmAdapter::new(rpc)))
            }
        }
        "sui" => Ok(Box::new(SuiAdapter::new_with_module(
            rpc,
            cfg.package_id.clone(),
            cfg.module.clone(),
        ))),
        other => Err(anyhow!(
            "unsupported chain_kind '{other}' for chain '{}'",
            cfg.name
        )),
    }
}

async fn build_runtime(cfg: ChainConfig) -> Result<ChainRuntime> {
    if cfg.skip_rpc {
        return Ok(ChainRuntime {
            config: cfg,
            block_number: 0,
            adapter: None,
        });
    }

    let adapter = build_adapter_from_config(&cfg)?;
    let block_number = adapter.get_block_number().await?;
    Ok(ChainRuntime {
        config: cfg,
        block_number,
        adapter: Some(adapter),
    })
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

fn poll_interval_secs() -> u64 {
    env::var("SOLVER_POLL_INTERVAL_SECS")
        .ok()
        .and_then(|v| v.parse::<u64>().ok())
        .unwrap_or(3)
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

fn chain_meta(rt: &ChainRuntime) -> serde_json::Value {
    serde_json::json!({
        "name": rt.config.name,
        "chain_kind": rt.config.chain_kind,
        "chain_id": rt.config.chain_id,
        "block_number": rt.block_number,
        "skip_rpc": rt.config.skip_rpc,
    })
}

fn select_source_runtime<'a>(
    srcs: &'a [ChainRuntime],
    intent: &IntentSubmittedEvent,
) -> Result<&'a ChainRuntime> {
    if let Some(found) = srcs
        .iter()
        .find(|s| s.config.chain_id == Some(intent.intent.src_chain_id))
    {
        return Ok(found);
    }
    srcs.first()
        .ok_or_else(|| anyhow!("no source chain config available"))
}

fn select_destination_runtime<'a>(
    dsts: &'a [ChainRuntime],
    intent: &IntentSubmittedEvent,
) -> Result<&'a ChainRuntime> {
    if let Some(found) = dsts
        .iter()
        .find(|d| d.config.chain_id == Some(intent.intent.dst_chain_id))
    {
        return Ok(found);
    }
    dsts.first()
        .ok_or_else(|| anyhow!("no destination chain config available"))
}

#[tokio::main]
async fn main() -> Result<()> {
    if use_chain_polling() {
        loop {
            let cycle = async {
                let src_configs = load_chain_configs("SOLVER_SRC")?;
                let dst_configs = load_chain_configs("SOLVER_DST")?;

                let mut src_runtimes = Vec::with_capacity(src_configs.len());
                for cfg in src_configs {
                    src_runtimes.push(build_runtime(cfg).await?);
                }

                let mut dst_runtimes = Vec::with_capacity(dst_configs.len());
                for cfg in dst_configs {
                    dst_runtimes.push(build_runtime(cfg).await?);
                }

                let from_block: u64 = env::var("SOLVER_FROM_BLOCK")
                    .unwrap_or_else(|_| "0".to_string())
                    .parse()
                    .context("invalid SOLVER_FROM_BLOCK")?;
                let to_block_override: Option<u64> = env::var("SOLVER_TO_BLOCK")
                    .ok()
                    .map(|v| v.parse().context("invalid SOLVER_TO_BLOCK"))
                    .transpose()?;

                if enrich_polled_intents() {
                    let mut by_source = Vec::new();
                    for src in &src_runtimes {
                        let to_block = to_block_override.unwrap_or(src.block_number);
                        let events = if let Some(adapter) = src.adapter.as_ref() {
                            adapter.fetch_intent_events(from_block, to_block).await?
                        } else {
                            load_polled_intent_events()?
                        };
                        for event in &events {
                            try_append_flow_event(
                                "intent_submitted",
                                &event.intent.intent_hash,
                                serde_json::to_value(event)
                                    .unwrap_or_else(|_| serde_json::json!({})),
                            );
                        }
                        by_source.push(serde_json::json!({
                            "source_chain": chain_meta(src),
                            "from_block": from_block,
                            "to_block": to_block,
                            "intent_submitted_events": events,
                        }));
                    }

                    println!(
                        "{}",
                        serde_json::to_string_pretty(&serde_json::json!({
                            "source_chains": src_runtimes.iter().map(chain_meta).collect::<Vec<_>>(),
                            "destination_chains": dst_runtimes.iter().map(chain_meta).collect::<Vec<_>>(),
                            "polled_intent_events_by_source": by_source,
                        }))
                        .context("failed to encode polled intent events")?
                    );
                } else {
                    let mut by_source = Vec::new();
                    for src in &src_runtimes {
                        let to_block = to_block_override.unwrap_or(src.block_number);
                        let refs = if let Some(adapter) = src.adapter.as_ref() {
                            adapter.fetch_intent_submissions(from_block, to_block).await?
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
                        by_source.push(serde_json::json!({
                            "source_chain": chain_meta(src),
                            "from_block": from_block,
                            "to_block": to_block,
                            "intent_submission_refs": refs,
                        }));
                    }

                    println!(
                        "{}",
                        serde_json::to_string_pretty(&serde_json::json!({
                            "source_chains": src_runtimes.iter().map(chain_meta).collect::<Vec<_>>(),
                            "destination_chains": dst_runtimes.iter().map(chain_meta).collect::<Vec<_>>(),
                            "polled_intent_refs_by_source": by_source,
                        }))
                        .context("failed to encode polled intent submissions")?
                    );
                }

                Ok::<(), anyhow::Error>(())
            }
            .await;

            if let Err(err) = cycle {
                eprintln!("solver polling cycle failed: {err}");
            }

            tokio::select! {
                _ = tokio::signal::ctrl_c() => {
                    eprintln!("solver received Ctrl+C, exiting");
                    break;
                }
                _ = sleep(Duration::from_secs(poll_interval_secs())) => {}
            }
        }

        return Ok(());
    }

    let src_configs = load_chain_configs("SOLVER_SRC")?;
    let dst_configs = load_chain_configs("SOLVER_DST")?;

    let mut src_runtimes = Vec::with_capacity(src_configs.len());
    for cfg in src_configs {
        src_runtimes.push(build_runtime(cfg).await?);
    }

    let mut dst_runtimes = Vec::with_capacity(dst_configs.len());
    for cfg in dst_configs {
        dst_runtimes.push(build_runtime(cfg).await?);
    }

    let event = load_intent_event()?;
    let solver = env::var("SOLVER_ADDRESS").unwrap_or_else(|_| "solver-local".to_string());
    let validator = env::var("VALIDATOR_ADDRESS").unwrap_or_else(|_| "validator-local".to_string());
    let amount_out = event.intent.min_dst_amount;

    let src = select_source_runtime(&src_runtimes, &event)?;
    let dst = select_destination_runtime(&dst_runtimes, &event)?;

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

    let src_action_target = src
        .config
        .endpoint_address
        .as_deref()
        .or(src.config.package_id.as_deref());

    let settlement_action = build_settlement_action(
        &src.config.chain_kind,
        src_action_target,
        src.config.state_object_id.as_deref(),
        &proposal,
    )?;

    let payload = serde_json::json!({
        "source_chain": chain_meta(src),
        "destination_chain": chain_meta(dst),
        "source_chains": src_runtimes.iter().map(chain_meta).collect::<Vec<_>>(),
        "destination_chains": dst_runtimes.iter().map(chain_meta).collect::<Vec<_>>(),
        "proposal": proposal,
        "recommended_settlement_action": settlement_action
    });
    println!(
        "{}",
        serde_json::to_string_pretty(&payload).context("failed to encode proposal payload")?
    );

    Ok(())
}
