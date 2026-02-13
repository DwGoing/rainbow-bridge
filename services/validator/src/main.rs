use alloy::primitives::{Address, Bytes};
use alloy::providers::{Provider, ProviderBuilder};
use alloy::rpc::types::{TransactionInput, TransactionRequest};
use alloy::signers::local::PrivateKeySigner;
use anyhow::{Context, Result, anyhow};
use chain_adapters::{ChainAdapter, EvmAdapter, SuiAdapter};
use std::collections::HashMap;
use std::env;
use std::fs::OpenOptions;
use std::io::Write;
use std::path::Path;
use std::str::FromStr;
use std::time::{SystemTime, UNIX_EPOCH};
use tokio::process::Command;
use tokio::time::{Duration, timeout};
use types::{SettlementProposal, SettlementProposalRef};
use validator::{
    SettlementActionKind, build_settlement_action_payload, encode_settlement_call,
    plan_settlement_action, validate_proposal,
};

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

fn now_unix() -> Result<u64> {
    Ok(SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|e| anyhow!("system time error: {e}"))?
        .as_secs())
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
        "timestamp": now_unix().unwrap_or(0),
        "source": "validator",
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

fn load_proposal() -> Result<SettlementProposal> {
    let raw =
        env::var("VALIDATOR_PROPOSAL_JSON").context("missing VALIDATOR_PROPOSAL_JSON input")?;
    let proposal: SettlementProposal =
        serde_json::from_str(&raw).context("invalid VALIDATOR_PROPOSAL_JSON")?;
    Ok(proposal)
}

fn load_polled_proposals() -> Result<Vec<SettlementProposalRef>> {
    let raw = env::var("VALIDATOR_POLLED_PROPOSALS_JSON")
        .context("missing VALIDATOR_POLLED_PROPOSALS_JSON input")?;
    let proposals: Vec<SettlementProposalRef> =
        serde_json::from_str(&raw).context("invalid VALIDATOR_POLLED_PROPOSALS_JSON")?;
    Ok(proposals)
}

fn load_polled_proposals_by_source() -> Result<Option<HashMap<String, Vec<SettlementProposalRef>>>>
{
    let raw = match env::var("VALIDATOR_POLLED_PROPOSALS_BY_SOURCE_JSON") {
        Ok(v) => v,
        Err(_) => return Ok(None),
    };
    let parsed: HashMap<String, Vec<SettlementProposalRef>> =
        serde_json::from_str(&raw).context("invalid VALIDATOR_POLLED_PROPOSALS_BY_SOURCE_JSON")?;
    Ok(Some(parsed))
}

fn normalize_chain_config(idx: usize, input: ChainConfigInput, _prefix: &str) -> ChainConfig {
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

fn parse_legacy_chain_config(prefix: &str) -> Result<ChainConfig> {
    let chain_kind = env::var(format!("{prefix}_CHAIN_KIND")).unwrap_or_else(|_| "evm".to_string());
    let skip_rpc = env::var(format!("{prefix}_SKIP_RPC"))
        .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
        .unwrap_or(false);
    let rpc_url = env::var(format!("{prefix}_RPC_URL")).ok();

    if !skip_rpc && rpc_url.is_none() {
        return Err(anyhow!("missing {prefix}_RPC_URL for selected chain"));
    }

    let chain_id = env::var(format!("{prefix}_CHAIN_ID"))
        .ok()
        .and_then(|v| v.parse::<u64>().ok());

    Ok(ChainConfig {
        name: format!("{}_default", prefix.to_lowercase()),
        chain_kind: chain_kind.to_lowercase(),
        rpc_url,
        endpoint_address: env::var(format!("{prefix}_ENDPOINT_ADDRESS")).ok(),
        package_id: env::var(format!("{prefix}_PACKAGE_ID"))
            .ok()
            .or_else(|| env::var(format!("{prefix}_ENDPOINT_ADDRESS")).ok()),
        state_object_id: env::var(format!("{prefix}_STATE_OBJECT_ID")).ok(),
        module: env::var(format!("{prefix}_MODULE")).unwrap_or_else(|_| "bridge".to_string()),
        skip_rpc,
        chain_id,
    })
}

fn load_chain_configs(prefix: &str) -> Result<Vec<ChainConfig>> {
    let key = format!("{prefix}_CHAINS_JSON");
    if let Ok(raw) = env::var(&key) {
        let parsed: Vec<ChainConfigInput> =
            serde_json::from_str(&raw).with_context(|| format!("invalid {key}"))?;
        if parsed.is_empty() {
            return Err(anyhow!("{key} cannot be empty"));
        }
        let mut out = Vec::with_capacity(parsed.len());
        for (idx, cfg) in parsed.into_iter().enumerate() {
            let normalized = normalize_chain_config(idx, cfg, prefix);
            if !normalized.skip_rpc && normalized.rpc_url.is_none() {
                return Err(anyhow!("{key}[{idx}] requires rpc_url when skip_rpc=false"));
            }
            out.push(normalized);
        }
        Ok(out)
    } else {
        Ok(vec![parse_legacy_chain_config(prefix)?])
    }
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
    env::var("VALIDATOR_USE_CHAIN_POLLING")
        .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
        .unwrap_or(false)
}

fn challenge_window_secs() -> Result<u64> {
    let v = env::var("VALIDATOR_CHALLENGE_WINDOW_SECS").unwrap_or_else(|_| "600".to_string());
    v.parse().context("invalid VALIDATOR_CHALLENGE_WINDOW_SECS")
}

fn settlement_call_payload(
    source_chain_kind: &str,
    endpoint: Option<&str>,
    state_object_id: Option<&str>,
    method: &str,
    intent_hash: &str,
    now_ts: Option<u64>,
) -> Result<serde_json::Value> {
    build_settlement_action_payload(
        source_chain_kind,
        endpoint.unwrap_or(""),
        state_object_id,
        method,
        intent_hash,
        now_ts,
    )
}

fn settlement_call_payload_fallback(
    source_chain_kind: &str,
    endpoint: Option<&str>,
    state_object_id: Option<&str>,
    method: &str,
    intent_hash: &str,
    now_ts: Option<u64>,
    err: &str,
) -> serde_json::Value {
    serde_json::json!({
        "chain_kind": source_chain_kind,
        "to": endpoint.unwrap_or(""),
        "state_object_id": state_object_id.unwrap_or(""),
        "method": method,
        "args": [intent_hash],
        "now_ts": now_ts.unwrap_or(0),
        "data": "",
        "encode_error": err
    })
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum TxMode {
    Off,
    DryRun,
    Send,
}

#[derive(Debug, Clone)]
struct ExecutableTx {
    source_chain: String,
    rpc_url: String,
    intent_hash: String,
    method: String,
    to: Address,
    data: Bytes,
}

#[derive(Debug, Clone)]
struct ExecutableSuiCall {
    source_chain: String,
    intent_hash: String,
    method: String,
    package: String,
    module: String,
    function: String,
    args: Vec<serde_json::Value>,
}

fn tx_mode() -> TxMode {
    match env::var("VALIDATOR_TX_MODE")
        .unwrap_or_else(|_| "off".to_string())
        .to_lowercase()
        .as_str()
    {
        "dry-run" | "dry_run" | "dryrun" => TxMode::DryRun,
        "send" => TxMode::Send,
        _ => TxMode::Off,
    }
}

fn make_tx_request(tx: &ExecutableTx) -> TransactionRequest {
    TransactionRequest::default()
        .to(tx.to)
        .input(TransactionInput::new(tx.data.clone()))
}

fn wait_receipt_enabled() -> bool {
    env::var("VALIDATOR_TX_WAIT_RECEIPT")
        .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
        .unwrap_or(false)
}

fn wait_receipt_timeout_secs() -> u64 {
    env::var("VALIDATOR_TX_RECEIPT_TIMEOUT_SECS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(120)
}

fn json_arg_to_cli_literal(v: &serde_json::Value) -> String {
    match v {
        serde_json::Value::String(s) => s.clone(),
        serde_json::Value::Number(n) => n.to_string(),
        serde_json::Value::Array(items) => {
            let mut out = String::from("[");
            for (i, it) in items.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                out.push_str(&json_arg_to_cli_literal(it));
            }
            out.push(']');
            out
        }
        _ => v.to_string(),
    }
}

fn find_line_value<'a>(text: &'a str, prefix: &str) -> Option<&'a str> {
    text.lines()
        .find_map(|line| line.trim().strip_prefix(prefix).map(str::trim))
}

fn parse_sui_digest(stdout: &str, stderr: &str) -> Option<String> {
    let from_stdout = find_line_value(stdout, "Transaction Digest:")
        .or_else(|| find_line_value(stdout, "Digest:"))
        .map(ToString::to_string);
    if from_stdout.is_some() {
        return from_stdout;
    }
    find_line_value(stderr, "Transaction Digest:")
        .or_else(|| find_line_value(stderr, "Digest:"))
        .map(ToString::to_string)
}

fn parse_sui_success(stdout: &str, stderr: &str) -> Option<bool> {
    let lower_out = stdout.to_ascii_lowercase();
    if lower_out.contains("execution status: success")
        || lower_out.contains("\"status\":\"success\"")
        || lower_out.contains("\"status\": \"success\"")
    {
        return Some(true);
    }
    if lower_out.contains("execution status: failure")
        || lower_out.contains("\"status\":\"failure\"")
        || lower_out.contains("\"status\": \"failure\"")
    {
        return Some(false);
    }

    let lower_err = stderr.to_ascii_lowercase();
    if lower_err.contains("execution status: success") {
        return Some(true);
    }
    if lower_err.contains("execution status: failure") {
        return Some(false);
    }
    None
}

async fn execute_evm_txs(mode: TxMode, txs: &[ExecutableTx]) -> Result<Vec<serde_json::Value>> {
    if mode == TxMode::Off {
        return Ok(Vec::new());
    }

    let signer = if mode == TxMode::Send {
        let pk = env::var("VALIDATOR_TX_PRIVATE_KEY")
            .context("VALIDATOR_TX_MODE=send requires VALIDATOR_TX_PRIVATE_KEY")?;
        Some(
            pk.parse::<PrivateKeySigner>()
                .context("invalid VALIDATOR_TX_PRIVATE_KEY")?,
        )
    } else {
        None
    };

    let mut results = Vec::with_capacity(txs.len());
    for tx in txs {
        let url = tx
            .rpc_url
            .parse()
            .with_context(|| format!("invalid rpc_url for source chain {}", tx.source_chain))?;
        let req = make_tx_request(tx);

        match mode {
            TxMode::DryRun => {
                let provider = ProviderBuilder::new().connect_http(url);
                let gas = provider
                    .estimate_gas(req)
                    .await
                    .map_err(|e| anyhow!("dry-run estimate_gas failed: {e}"));
                match gas {
                    Ok(estimated_gas) => results.push(serde_json::json!({
                        "source_chain": tx.source_chain,
                        "intent_hash": tx.intent_hash,
                        "method": tx.method,
                        "status": "simulated",
                        "estimated_gas": estimated_gas
                    })),
                    Err(err) => results.push(serde_json::json!({
                        "source_chain": tx.source_chain,
                        "intent_hash": tx.intent_hash,
                        "method": tx.method,
                        "status": "simulation_failed",
                        "error": err.to_string()
                    })),
                }
            }
            TxMode::Send => {
                let signer = signer
                    .clone()
                    .ok_or_else(|| anyhow!("missing signer for send mode"))?;
                let provider = ProviderBuilder::new().wallet(signer).connect_http(url);
                let sent = provider.send_transaction(req).await;
                match sent {
                    Ok(pending) => {
                        let tx_hash = format!("{:#x}", pending.tx_hash());
                        if wait_receipt_enabled() {
                            let receipt_result = timeout(
                                Duration::from_secs(wait_receipt_timeout_secs()),
                                pending.get_receipt(),
                            )
                            .await;
                            match receipt_result {
                                Ok(Ok(receipt)) => results.push(serde_json::json!({
                                    "source_chain": tx.source_chain,
                                    "intent_hash": tx.intent_hash,
                                    "method": tx.method,
                                    "status": "confirmed",
                                    "tx_hash": tx_hash,
                                    "block_number": receipt.block_number,
                                    "success": receipt.status()
                                })),
                                Ok(Err(err)) => results.push(serde_json::json!({
                                    "source_chain": tx.source_chain,
                                    "intent_hash": tx.intent_hash,
                                    "method": tx.method,
                                    "status": "receipt_failed",
                                    "tx_hash": tx_hash,
                                    "error": err.to_string()
                                })),
                                Err(_) => results.push(serde_json::json!({
                                    "source_chain": tx.source_chain,
                                    "intent_hash": tx.intent_hash,
                                    "method": tx.method,
                                    "status": "receipt_timeout",
                                    "tx_hash": tx_hash,
                                    "timeout_secs": wait_receipt_timeout_secs()
                                })),
                            }
                        } else {
                            results.push(serde_json::json!({
                                "source_chain": tx.source_chain,
                                "intent_hash": tx.intent_hash,
                                "method": tx.method,
                                "status": "sent",
                                "tx_hash": tx_hash
                            }));
                        }
                    }
                    Err(err) => results.push(serde_json::json!({
                        "source_chain": tx.source_chain,
                        "intent_hash": tx.intent_hash,
                        "method": tx.method,
                        "status": "send_failed",
                        "error": err.to_string()
                    })),
                }
            }
            TxMode::Off => {}
        }
    }

    Ok(results)
}

async fn execute_sui_calls(
    mode: TxMode,
    calls: &[ExecutableSuiCall],
) -> Result<Vec<serde_json::Value>> {
    if mode == TxMode::Off {
        return Ok(Vec::new());
    }

    let cli_bin = env::var("VALIDATOR_SUI_CLI_BIN").unwrap_or_else(|_| "sui".to_string());
    let sender = env::var("VALIDATOR_SUI_SENDER").ok();
    let gas_budget = env::var("VALIDATOR_SUI_GAS_BUDGET")
        .ok()
        .and_then(|v| v.parse::<u64>().ok())
        .unwrap_or(10_000_000);

    let mut results = Vec::with_capacity(calls.len());
    for call in calls {
        let mut cmd = Command::new(&cli_bin);
        cmd.arg("client")
            .arg("call")
            .arg("--package")
            .arg(&call.package)
            .arg("--module")
            .arg(&call.module)
            .arg("--function")
            .arg(&call.function)
            .arg("--gas-budget")
            .arg(gas_budget.to_string());

        if let Some(s) = sender.as_ref() {
            cmd.arg("--sender").arg(s);
        }

        if !call.args.is_empty() {
            cmd.arg("--args");
            for arg in &call.args {
                cmd.arg(json_arg_to_cli_literal(arg));
            }
        }

        if mode == TxMode::DryRun {
            cmd.arg("--dry-run");
        }

        let output = cmd
            .output()
            .await
            .map_err(|e| anyhow!("failed to execute sui cli: {e}"))?;

        let stdout = String::from_utf8_lossy(&output.stdout).to_string();
        let stderr = String::from_utf8_lossy(&output.stderr).to_string();
        let tx_digest = parse_sui_digest(&stdout, &stderr);
        let success = parse_sui_success(&stdout, &stderr);
        if output.status.success() {
            results.push(serde_json::json!({
                "source_chain": call.source_chain,
                "intent_hash": call.intent_hash,
                "method": call.method,
                "status": if mode == TxMode::DryRun { "simulated" } else { "sent" },
                "tx_digest": tx_digest,
                "success": success,
                "exit_code": output.status.code(),
                "output": stdout
            }));
        } else {
            results.push(serde_json::json!({
                "source_chain": call.source_chain,
                "intent_hash": call.intent_hash,
                "method": call.method,
                "status": if mode == TxMode::DryRun { "simulation_failed" } else { "send_failed" },
                "tx_digest": tx_digest,
                "success": success,
                "exit_code": output.status.code(),
                "error": stderr
            }));
        }
    }

    Ok(results)
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

fn select_source_runtime<'a>(srcs: &'a [ChainRuntime]) -> Result<&'a ChainRuntime> {
    if let Ok(name) = env::var("VALIDATOR_SOURCE_CHAIN_NAME") {
        if let Some(rt) = srcs.iter().find(|s| s.config.name == name) {
            return Ok(rt);
        }
    }

    if let Ok(id) = env::var("VALIDATOR_SOURCE_CHAIN_ID") {
        if let Ok(chain_id) = id.parse::<u64>() {
            if let Some(rt) = srcs.iter().find(|s| s.config.chain_id == Some(chain_id)) {
                return Ok(rt);
            }
        }
    }

    srcs.first()
        .ok_or_else(|| anyhow!("no source chain config available"))
}

fn select_destination_runtime<'a>(dsts: &'a [ChainRuntime]) -> Result<&'a ChainRuntime> {
    dsts.first()
        .ok_or_else(|| anyhow!("no destination chain config available"))
}

#[tokio::main]
async fn main() -> Result<()> {
    let ts = now_unix()?;

    let src_configs = load_chain_configs("VALIDATOR_SRC")?;
    let dst_configs = load_chain_configs("VALIDATOR_DST")?;

    let mut src_runtimes = Vec::with_capacity(src_configs.len());
    for cfg in src_configs {
        src_runtimes.push(build_runtime(cfg).await?);
    }

    let mut dst_runtimes = Vec::with_capacity(dst_configs.len());
    for cfg in dst_configs {
        dst_runtimes.push(build_runtime(cfg).await?);
    }

    if use_chain_polling() {
        let from_block: u64 = env::var("VALIDATOR_FROM_BLOCK")
            .unwrap_or_else(|_| "0".to_string())
            .parse()
            .context("invalid VALIDATOR_FROM_BLOCK")?;
        let to_block_override: Option<u64> = env::var("VALIDATOR_TO_BLOCK")
            .ok()
            .map(|v| v.parse().context("invalid VALIDATOR_TO_BLOCK"))
            .transpose()?;

        let by_source_fallback = load_polled_proposals().ok();
        let by_source = load_polled_proposals_by_source()?;

        let now = ts;
        let window = challenge_window_secs()?;
        let mut executable_txs = Vec::<ExecutableTx>::new();
        let mut executable_sui_calls = Vec::<ExecutableSuiCall>::new();
        let mut decisions = Vec::new();

        for src in &src_runtimes {
            let to_block = to_block_override.unwrap_or(src.block_number);
            let proposals = if let Some(adapter) = src.adapter.as_ref() {
                adapter
                    .fetch_settlement_proposals(from_block, to_block)
                    .await?
            } else if let Some(map) = by_source.as_ref() {
                map.get(&src.config.name).cloned().unwrap_or_default()
            } else {
                by_source_fallback.clone().unwrap_or_default()
            };

            for p in &proposals {
                let plan = plan_settlement_action(p, now, window);
                let target = src
                    .config
                    .endpoint_address
                    .as_deref()
                    .or(src.config.package_id.as_deref());

                let tx_payload = match plan.action {
                    SettlementActionKind::Challenge => Some(
                        settlement_call_payload(
                            &src.config.chain_kind,
                            target,
                            src.config.state_object_id.as_deref(),
                            "challengeSettlement",
                            &p.intent_hash,
                            Some(now),
                        )
                        .unwrap_or_else(|e| {
                            settlement_call_payload_fallback(
                                &src.config.chain_kind,
                                target,
                                src.config.state_object_id.as_deref(),
                                "challengeSettlement",
                                &p.intent_hash,
                                Some(now),
                                &e.to_string(),
                            )
                        }),
                    ),
                    SettlementActionKind::Finalize => Some(
                        settlement_call_payload(
                            &src.config.chain_kind,
                            target,
                            src.config.state_object_id.as_deref(),
                            "finalizeSettlement",
                            &p.intent_hash,
                            Some(now),
                        )
                        .unwrap_or_else(|e| {
                            settlement_call_payload_fallback(
                                &src.config.chain_kind,
                                target,
                                src.config.state_object_id.as_deref(),
                                "finalizeSettlement",
                                &p.intent_hash,
                                Some(now),
                                &e.to_string(),
                            )
                        }),
                    ),
                    SettlementActionKind::Hold => None,
                };

                if matches!(
                    plan.action,
                    SettlementActionKind::Challenge | SettlementActionKind::Finalize
                ) {
                    if src.config.chain_kind == "evm" {
                        if let (Some(to_str), Some(rpc_url)) =
                            (target, src.config.rpc_url.as_deref())
                        {
                            if let Ok(to_addr) = Address::from_str(to_str) {
                                let method = match plan.action {
                                    SettlementActionKind::Challenge => "challengeSettlement",
                                    SettlementActionKind::Finalize => "finalizeSettlement",
                                    SettlementActionKind::Hold => "hold",
                                };
                                if let Ok(encoded) = encode_settlement_call(method, &p.intent_hash)
                                {
                                    if let Ok(raw) =
                                        alloy::hex::decode(encoded.trim_start_matches("0x"))
                                    {
                                        let data = Bytes::from(raw);
                                        executable_txs.push(ExecutableTx {
                                            source_chain: src.config.name.clone(),
                                            rpc_url: rpc_url.to_string(),
                                            intent_hash: p.intent_hash.clone(),
                                            method: method.to_string(),
                                            to: to_addr,
                                            data,
                                        });
                                    }
                                }
                            }
                        }
                    } else if src.config.chain_kind == "sui" {
                        if let Some(payload) = tx_payload.as_ref() {
                            let package =
                                payload["package"].as_str().unwrap_or_default().to_string();
                            let module = payload["module"].as_str().unwrap_or("bridge").to_string();
                            let function =
                                payload["function"].as_str().unwrap_or_default().to_string();
                            let args = payload["args"].as_array().cloned().unwrap_or_default();
                            let method = match plan.action {
                                SettlementActionKind::Challenge => "challengeSettlement",
                                SettlementActionKind::Finalize => "finalizeSettlement",
                                SettlementActionKind::Hold => "hold",
                            };
                            executable_sui_calls.push(ExecutableSuiCall {
                                source_chain: src.config.name.clone(),
                                intent_hash: p.intent_hash.clone(),
                                method: method.to_string(),
                                package,
                                module,
                                function,
                                args,
                            });
                        }
                    }
                }

                decisions.push(serde_json::json!({
                    "source_chain": src.config.name,
                    "source_chain_kind": src.config.chain_kind,
                    "intent_hash": p.intent_hash,
                    "validator": p.validator,
                    "solver": p.solver,
                    "amount_out": p.amount_out,
                    "tx_hash": p.tx_hash,
                    "block_number": p.block_number,
                    "timestamp": p.timestamp,
                    "decision": plan.decision,
                    "action": format!("{:?}", plan.action).to_lowercase(),
                    "reason": plan.reason,
                    "recommended_tx": tx_payload
                }));
            }
        }

        let mode = tx_mode();
        let mut execution_results = Vec::new();
        execution_results.extend(execute_evm_txs(mode, &executable_txs).await?);
        execution_results.extend(execute_sui_calls(mode, &executable_sui_calls).await?);

        for d in &decisions {
            if let Some(intent_hash) = d["intent_hash"].as_str() {
                try_append_flow_event("validator_decision", intent_hash, d.clone());
            }
        }
        for e in &execution_results {
            if let Some(intent_hash) = e["intent_hash"].as_str() {
                try_append_flow_event("execution_result", intent_hash, e.clone());
            }
        }

        let mode_label = match mode {
            TxMode::Off => "off",
            TxMode::DryRun => "dry-run",
            TxMode::Send => "send",
        };

        println!(
            "{}",
            serde_json::to_string_pretty(&serde_json::json!({
                "timestamp": ts,
                "source_chains": src_runtimes.iter().map(chain_meta).collect::<Vec<_>>(),
                "destination_chains": dst_runtimes.iter().map(chain_meta).collect::<Vec<_>>(),
                "tx_mode": mode_label,
                "polled_settlement_decisions": decisions,
                "execution_results": execution_results
            }))
            .context("failed to encode polled settlement decisions")?
        );
        return Ok(());
    }

    let proposal = load_proposal()?;
    let decision = validate_proposal(&proposal);
    let src = select_source_runtime(&src_runtimes)?;
    let dst = select_destination_runtime(&dst_runtimes)?;

    try_append_flow_event(
        "validator_decision",
        &proposal.intent_hash,
        serde_json::json!({
            "intent_hash": proposal.intent_hash,
            "decision": decision,
            "source_chain": src.config.name,
        }),
    );

    println!(
        "{}",
        serde_json::to_string_pretty(&serde_json::json!({
            "intent_hash": proposal.intent_hash,
            "timestamp": ts,
            "source_chain": chain_meta(src),
            "destination_chain": chain_meta(dst),
            "source_chains": src_runtimes.iter().map(chain_meta).collect::<Vec<_>>(),
            "destination_chains": dst_runtimes.iter().map(chain_meta).collect::<Vec<_>>(),
            "decision": decision
        }))
        .context("failed to encode validator decision")?
    );

    Ok(())
}
