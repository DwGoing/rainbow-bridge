use alloy::primitives::{B256, U256};
use alloy::sol_types::SolCall;
use anyhow::{Result, anyhow};
use std::str::FromStr;
use std::time::{SystemTime, UNIX_EPOCH};
use types::{ExecutionProof, IntentSubmittedEvent, SettlementProposal};

alloy::sol! {
    function proposeSettlement(bytes32 intentHash, uint256 amountOut);
}

fn now_unix() -> Result<u64> {
    Ok(SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|e| anyhow!("system time error: {e}"))?
        .as_secs())
}

pub fn build_proposal(
    event: &IntentSubmittedEvent,
    solver: &str,
    validator: &str,
    amount_out: u128,
) -> Result<SettlementProposal> {
    let proof = ExecutionProof {
        intent_hash: event.intent.intent_hash.clone(),
        dst_chain_id: event.intent.dst_chain_id,
        dst_tx_hash: format!("simulated-dst-tx-{}", event.intent.intent_hash),
        amount_out,
        receiver: event.intent.recipient.clone(),
        solver: solver.to_string(),
    };

    Ok(SettlementProposal {
        intent_hash: event.intent.intent_hash.clone(),
        validator: validator.to_string(),
        solver: solver.to_string(),
        amount_out,
        execution_proof: proof,
        proposed_at: now_unix()?,
    })
}

pub fn build_settlement_action(
    src_chain_kind: &str,
    src_endpoint: Option<&str>,
    src_state_object_id: Option<&str>,
    proposal: &SettlementProposal,
) -> Result<serde_json::Value> {
    match src_chain_kind {
        "evm" => {
            let hash = B256::from_str(&proposal.intent_hash)
                .map_err(|e| anyhow!("invalid intent hash '{}': {e}", proposal.intent_hash))?;
            let call = proposeSettlementCall {
                intentHash: hash,
                amountOut: U256::from(proposal.amount_out),
            };
            let data = format!("0x{}", alloy::hex::encode(call.abi_encode()));
            Ok(serde_json::json!({
                "chain_kind": "evm",
                "to": src_endpoint.unwrap_or(""),
                "method": "proposeSettlement",
                "args": [proposal.intent_hash, proposal.amount_out],
                "data": data
            }))
        }
        "sui" => {
            let state_object_id = src_state_object_id.ok_or_else(|| {
                anyhow!("missing source state object id for sui settlement action")
            })?;
            let intent_hash_bytes = hex_to_u8_vec(&proposal.intent_hash)?;
            Ok(serde_json::json!({
                "chain_kind": "sui",
                "package": src_endpoint.unwrap_or(""),
                "module": "bridge",
                "function": "propose_settlement",
                "type_args": [],
                "args": [state_object_id, "0x0", intent_hash_bytes, proposal.amount_out, proposal.proposed_at]
            }))
        }
        other => Err(anyhow!("unsupported source chain kind '{other}'")),
    }
}

fn hex_to_u8_vec(hex: &str) -> Result<Vec<u8>> {
    let normalized = hex.strip_prefix("0x").unwrap_or(hex);
    if normalized.is_empty() {
        return Ok(Vec::new());
    }
    if normalized.len() % 2 != 0 {
        return Err(anyhow!("hex string has odd length: {hex}"));
    }
    alloy::hex::decode(normalized).map_err(|e| anyhow!("invalid hex string '{hex}': {e}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use types::{IntentSubmittedEvent, SwapIntent};

    #[test]
    fn proposal_contains_matching_intent_hash() {
        let event = IntentSubmittedEvent {
            intent: SwapIntent {
                intent_hash: "0xintent".to_string(),
                provider: "0xprovider".to_string(),
                src_chain_id: 1,
                src_token: "0xsrc".to_string(),
                src_amount: 100,
                dst_chain_id: 2,
                dst_token: "0xdst".to_string(),
                min_dst_amount: 90,
                recipient: "0xreceiver".to_string(),
                deadline: 1000,
                nonce: 1,
            },
            tx_hash: "0xtx".to_string(),
            block_number: 10,
            timestamp: 100,
        };

        let proposal = build_proposal(&event, "0xsolver", "0xvalidator", 95).unwrap();
        assert_eq!(proposal.intent_hash, "0xintent");
        assert_eq!(proposal.execution_proof.intent_hash, "0xintent");
        assert_eq!(proposal.amount_out, 95);
    }

    #[test]
    fn build_settlement_action_for_evm() {
        let proposal = SettlementProposal {
            intent_hash: "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
                .to_string(),
            validator: "0xvalidator".to_string(),
            solver: "0xsolver".to_string(),
            amount_out: 1000,
            execution_proof: ExecutionProof {
                intent_hash: "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
                    .to_string(),
                dst_chain_id: 2,
                dst_tx_hash: "0xtx".to_string(),
                amount_out: 1000,
                receiver: "0xreceiver".to_string(),
                solver: "0xsolver".to_string(),
            },
            proposed_at: 1,
        };
        let action = build_settlement_action(
            "evm",
            Some("0x1111111111111111111111111111111111111111"),
            None,
            &proposal,
        )
        .unwrap();
        let data = action["data"].as_str().unwrap();
        assert!(data.starts_with("0x"));
        assert_eq!(data.len(), 138);
    }
}
