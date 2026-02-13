use alloy::primitives::{Address, Bytes};
use alloy::providers::{Provider, ProviderBuilder};
use alloy::rpc::types::{TransactionInput, TransactionRequest};
use alloy::signers::local::PrivateKeySigner;
use anyhow::{Context, Result, anyhow};
use chain_adapters::{ChainAdapter, ChainKind, EvmAdapter, SuiAdapter};
use std::env;
use std::str::FromStr;
use tokio::time::{Duration, timeout};
use std::time::{SystemTime, UNIX_EPOCH};
use types::{SettlementProposal, SettlementProposalRef};
use validator::{SettlementActionKind, encode_settlement_call, plan_settlement_action, validate_proposal};

fn now_unix() -> Result<u64> {
    Ok(SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|e| anyhow!("system time error: {e}"))?
        .as_secs())
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
        "sui" => Ok(Box::new(SuiAdapter::new(rpc))),
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
    env::var("VALIDATOR_USE_CHAIN_POLLING")
        .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
        .unwrap_or(false)
}

fn challenge_window_secs() -> Result<u64> {
    let v = env::var("VALIDATOR_CHALLENGE_WINDOW_SECS").unwrap_or_else(|_| "600".to_string());
    v.parse().context("invalid VALIDATOR_CHALLENGE_WINDOW_SECS")
}

fn settlement_call_payload(
    endpoint: Option<&str>,
    method: &str,
    intent_hash: &str
) -> Result<serde_json::Value> {
    let data = encode_settlement_call(method, intent_hash)?;

    Ok(serde_json::json!({
        "to": endpoint.unwrap_or(""),
        "method": method,
        "args": [intent_hash],
        "data": data
    }))
}

fn settlement_call_payload_fallback(
    endpoint: Option<&str>,
    method: &str,
    intent_hash: &str,
    err: &str,
) -> serde_json::Value {
    serde_json::json!({
        "to": endpoint.unwrap_or(""),
        "method": method,
        "args": [intent_hash],
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
    intent_hash: String,
    method: String,
    to: Address,
    data: Bytes,
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

async fn execute_txs(mode: TxMode, txs: &[ExecutableTx]) -> Result<Vec<serde_json::Value>> {
    if mode == TxMode::Off {
        return Ok(Vec::new());
    }

    let rpc = env::var("VALIDATOR_SRC_RPC_URL")
        .context("VALIDATOR_TX_MODE requires VALIDATOR_SRC_RPC_URL")?;
    let url = rpc.parse().context("invalid VALIDATOR_SRC_RPC_URL")?;

    match mode {
        TxMode::DryRun => {
            let provider = ProviderBuilder::new().connect_http(url);
            let mut results = Vec::with_capacity(txs.len());
            for tx in txs {
                let req = make_tx_request(tx);
                let gas = provider
                    .estimate_gas(req)
                    .await
                    .map_err(|e| anyhow!("dry-run estimate_gas failed: {e}"));
                match gas {
                    Ok(estimated_gas) => results.push(serde_json::json!({
                        "intent_hash": tx.intent_hash,
                        "method": tx.method,
                        "status": "simulated",
                        "estimated_gas": estimated_gas
                    })),
                    Err(err) => results.push(serde_json::json!({
                        "intent_hash": tx.intent_hash,
                        "method": tx.method,
                        "status": "simulation_failed",
                        "error": err.to_string()
                    })),
                }
            }
            Ok(results)
        }
        TxMode::Send => {
            let pk = env::var("VALIDATOR_TX_PRIVATE_KEY")
                .context("VALIDATOR_TX_MODE=send requires VALIDATOR_TX_PRIVATE_KEY")?;
            let signer: PrivateKeySigner = pk.parse().context("invalid VALIDATOR_TX_PRIVATE_KEY")?;
            let provider = ProviderBuilder::new().wallet(signer).connect_http(url);

            let mut results = Vec::with_capacity(txs.len());
            for tx in txs {
                let req = make_tx_request(tx);
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
                                    "intent_hash": tx.intent_hash,
                                    "method": tx.method,
                                    "status": "confirmed",
                                    "tx_hash": tx_hash,
                                    "block_number": receipt.block_number,
                                    "success": receipt.status()
                                })),
                                Ok(Err(err)) => results.push(serde_json::json!({
                                    "intent_hash": tx.intent_hash,
                                    "method": tx.method,
                                    "status": "receipt_failed",
                                    "tx_hash": tx_hash,
                                    "error": err.to_string()
                                })),
                                Err(_) => results.push(serde_json::json!({
                                    "intent_hash": tx.intent_hash,
                                    "method": tx.method,
                                    "status": "receipt_timeout",
                                    "tx_hash": tx_hash,
                                    "timeout_secs": wait_receipt_timeout_secs()
                                })),
                            }
                        } else {
                            results.push(serde_json::json!({
                                "intent_hash": tx.intent_hash,
                                "method": tx.method,
                                "status": "sent",
                                "tx_hash": tx_hash
                            }));
                        }
                    }
                    Err(err) => results.push(serde_json::json!({
                        "intent_hash": tx.intent_hash,
                        "method": tx.method,
                        "status": "send_failed",
                        "error": err.to_string()
                    })),
                }
            }
            Ok(results)
        }
        TxMode::Off => Ok(Vec::new()),
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    let ts = now_unix()?;
    let (src_kind, src_block, src_adapter) = if skip_rpc("VALIDATOR_SRC") {
        (chain_kind_from_env("VALIDATOR_SRC"), 0, None)
    } else {
        let adapter = build_adapter_from_env("VALIDATOR_SRC")?;
        let kind = match adapter.kind() {
            ChainKind::Evm => "evm".to_string(),
            ChainKind::Sui => "sui".to_string(),
        };
        let block = adapter.get_block_number().await?;
        (kind, block, Some(adapter))
    };
    let (dst_kind, dst_block) = if skip_rpc("VALIDATOR_DST") {
        (chain_kind_from_env("VALIDATOR_DST"), 0)
    } else {
        let adapter = build_adapter_from_env("VALIDATOR_DST")?;
        let kind = match adapter.kind() {
            ChainKind::Evm => "evm".to_string(),
            ChainKind::Sui => "sui".to_string(),
        };
        let block = adapter.get_block_number().await?;
        (kind, block)
    };

    if use_chain_polling() {
        let from_block: u64 = env::var("VALIDATOR_FROM_BLOCK")
            .unwrap_or_else(|_| "0".to_string())
            .parse()
            .context("invalid VALIDATOR_FROM_BLOCK")?;
        let to_block: u64 = env::var("VALIDATOR_TO_BLOCK")
            .unwrap_or_else(|_| src_block.to_string())
            .parse()
            .context("invalid VALIDATOR_TO_BLOCK")?;
        let proposals = if let Some(src) = src_adapter.as_ref() {
            src.fetch_settlement_proposals(from_block, to_block).await?
        } else {
            load_polled_proposals()?
        };
        let now = ts;
        let window = challenge_window_secs()?;
        let endpoint = env::var("VALIDATOR_SRC_ENDPOINT_ADDRESS").ok();
        let mut executable_txs = Vec::<ExecutableTx>::new();
        let mut decisions = Vec::with_capacity(proposals.len());
        for p in &proposals {
                let plan = plan_settlement_action(p, now, window);
                let tx_payload = match plan.action {
                    SettlementActionKind::Challenge => Some(
                        settlement_call_payload(
                            endpoint.as_deref(),
                            "challengeSettlement",
                            &p.intent_hash,
                        )
                        .unwrap_or_else(|e| {
                            settlement_call_payload_fallback(
                                endpoint.as_deref(),
                                "challengeSettlement",
                                &p.intent_hash,
                                &e.to_string(),
                            )
                        }),
                    ),
                    SettlementActionKind::Finalize => Some(
                        settlement_call_payload(
                            endpoint.as_deref(),
                            "finalizeSettlement",
                            &p.intent_hash,
                        )
                        .unwrap_or_else(|e| {
                            settlement_call_payload_fallback(
                                endpoint.as_deref(),
                                "finalizeSettlement",
                                &p.intent_hash,
                                &e.to_string(),
                            )
                        }),
                    ),
                    SettlementActionKind::Hold => None,
                };
                if matches!(plan.action, SettlementActionKind::Challenge | SettlementActionKind::Finalize) {
                    if let Some(to_str) = endpoint.as_deref() {
                        if let Ok(to_addr) = Address::from_str(to_str) {
                            let method = match plan.action {
                                SettlementActionKind::Challenge => "challengeSettlement",
                                SettlementActionKind::Finalize => "finalizeSettlement",
                                SettlementActionKind::Hold => "hold",
                            };
                            if let Ok(encoded) = encode_settlement_call(method, &p.intent_hash) {
                                if let Ok(raw) = alloy::hex::decode(encoded.trim_start_matches("0x")) {
                                    let data = Bytes::from(raw);
                                    executable_txs.push(ExecutableTx {
                                        intent_hash: p.intent_hash.clone(),
                                        method: method.to_string(),
                                        to: to_addr,
                                        data,
                                    });
                                }
                            }
                        }
                    }
                }
                decisions.push(serde_json::json!({
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

        let mode = tx_mode();
        let execution_results = execute_txs(mode, &executable_txs).await?;
        let mode_label = match mode {
            TxMode::Off => "off",
            TxMode::DryRun => "dry-run",
            TxMode::Send => "send",
        };

        println!(
            "{}",
            serde_json::to_string_pretty(&serde_json::json!({
                "timestamp": ts,
                "source_chain_kind": src_kind,
                "destination_chain_kind": dst_kind,
                "source_block_number": src_block,
                "destination_block_number": dst_block,
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

    println!(
        "{}",
        serde_json::to_string_pretty(&serde_json::json!({
            "intent_hash": proposal.intent_hash,
            "timestamp": ts,
            "source_chain_kind": src_kind,
            "destination_chain_kind": dst_kind,
            "source_block_number": src_block,
            "destination_block_number": dst_block,
            "decision": decision
        }))
        .context("failed to encode validator decision")?
    );

    Ok(())
}
