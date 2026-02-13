use alloy::primitives::B256;
use alloy::sol_types::SolCall;
use anyhow::{Result, anyhow};
use std::str::FromStr;
use types::{SettlementProposal, SettlementProposalRef, ValidatorDecision};

alloy::sol! {
    function challengeSettlement(bytes32 intentHash);
    function finalizeSettlement(bytes32 intentHash);
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SettlementActionKind {
    Challenge,
    Finalize,
    Hold,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SettlementActionPlan {
    pub intent_hash: String,
    pub decision: ValidatorDecision,
    pub action: SettlementActionKind,
    pub reason: String,
}

pub fn validate_proposal(proposal: &SettlementProposal) -> ValidatorDecision {
    if proposal.amount_out == 0 {
        return ValidatorDecision::Challenge("amount_out is zero".to_string());
    }
    if proposal.execution_proof.intent_hash != proposal.intent_hash {
        return ValidatorDecision::Challenge("proof intent_hash mismatch".to_string());
    }
    if proposal.execution_proof.amount_out < proposal.amount_out {
        return ValidatorDecision::Challenge("proof amount_out too small".to_string());
    }
    ValidatorDecision::Approve
}

pub fn plan_settlement_action(
    proposal: &SettlementProposalRef,
    now_ts: u64,
    challenge_window_secs: u64,
) -> SettlementActionPlan {
    if proposal.amount_out == 0 {
        return SettlementActionPlan {
            intent_hash: proposal.intent_hash.clone(),
            decision: ValidatorDecision::Challenge("amount_out is zero".to_string()),
            action: SettlementActionKind::Challenge,
            reason: "detected invalid proposal amount".to_string(),
        };
    }

    let deadline = proposal.timestamp.saturating_add(challenge_window_secs);
    if now_ts >= deadline {
        SettlementActionPlan {
            intent_hash: proposal.intent_hash.clone(),
            decision: ValidatorDecision::Approve,
            action: SettlementActionKind::Finalize,
            reason: "challenge window elapsed".to_string(),
        }
    } else {
        SettlementActionPlan {
            intent_hash: proposal.intent_hash.clone(),
            decision: ValidatorDecision::Approve,
            action: SettlementActionKind::Hold,
            reason: "waiting for challenge window".to_string(),
        }
    }
}

pub fn encode_settlement_call(method: &str, intent_hash: &str) -> Result<String> {
    let hash = B256::from_str(intent_hash)
        .map_err(|e| anyhow!("invalid intent hash '{intent_hash}': {e}"))?;
    let bytes = match method {
        "challengeSettlement" => challengeSettlementCall { intentHash: hash }.abi_encode(),
        "finalizeSettlement" => finalizeSettlementCall { intentHash: hash }.abi_encode(),
        _ => return Err(anyhow!("unsupported settlement method '{method}'")),
    };
    Ok(format!("0x{}", alloy::hex::encode(bytes)))
}

pub fn build_settlement_action_payload(
    source_chain_kind: &str,
    source_target: &str,
    source_state_object_id: Option<&str>,
    method: &str,
    intent_hash: &str,
    now_ts: Option<u64>,
) -> Result<serde_json::Value> {
    match source_chain_kind {
        "evm" => {
            let data = encode_settlement_call(method, intent_hash)?;
            Ok(serde_json::json!({
                "chain_kind": "evm",
                "to": source_target,
                "method": method,
                "args": [intent_hash],
                "data": data
            }))
        }
        "sui" => {
            let function = match method {
                "challengeSettlement" => "challenge_settlement",
                "finalizeSettlement" => "finalize_settlement",
                _ => return Err(anyhow!("unsupported settlement method '{method}' for sui")),
            };
            let state_object_id = source_state_object_id.ok_or_else(|| {
                anyhow!("missing source state object id for sui settlement action")
            })?;
            let intent_hash_bytes = hex_to_u8_vec(intent_hash)?;
            let ts = now_ts.unwrap_or(0);
            let args = match method {
                "challengeSettlement" => {
                    serde_json::json!([state_object_id, "0x0", intent_hash_bytes, ts])
                }
                "finalizeSettlement" => serde_json::json!([state_object_id, intent_hash_bytes, ts]),
                _ => unreachable!(),
            };
            Ok(serde_json::json!({
                "chain_kind": "sui",
                "package": source_target,
                "module": "bridge",
                "function": function,
                "type_args": [],
                "args": args
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
    use types::{ExecutionProof, SettlementProposal, SettlementProposalRef};

    #[test]
    fn invalid_proposal_is_challenged() {
        let proposal = SettlementProposal {
            intent_hash: "0xintent".to_string(),
            validator: "0xvalidator".to_string(),
            solver: "0xsolver".to_string(),
            amount_out: 10,
            execution_proof: ExecutionProof {
                intent_hash: "0xintent".to_string(),
                dst_chain_id: 2,
                dst_tx_hash: "0xtx".to_string(),
                amount_out: 9,
                receiver: "0xreceiver".to_string(),
                solver: "0xsolver".to_string(),
            },
            proposed_at: 10,
        };

        let decision = validate_proposal(&proposal);
        assert!(matches!(decision, ValidatorDecision::Challenge(_)));
    }

    #[test]
    fn actionable_plan_finalize_after_window() {
        let proposal_ref = SettlementProposalRef {
            intent_hash: "0xintent".to_string(),
            validator: "0xvalidator".to_string(),
            solver: "0xsolver".to_string(),
            amount_out: 100,
            tx_hash: "0xtx".to_string(),
            block_number: 1,
            timestamp: 100,
        };

        let plan = plan_settlement_action(&proposal_ref, 800, 600);
        assert!(matches!(plan.action, SettlementActionKind::Finalize));
        assert!(matches!(plan.decision, ValidatorDecision::Approve));
    }

    #[test]
    fn encoding_contains_expected_selectors() {
        let hash = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
        let challenge = encode_settlement_call("challengeSettlement", hash).unwrap();
        let finalize = encode_settlement_call("finalizeSettlement", hash).unwrap();

        assert!(challenge.starts_with("0x3b693c67"));
        assert!(finalize.starts_with("0x19f3b062"));
    }

    #[test]
    fn build_sui_action_payload() {
        let payload = build_settlement_action_payload(
            "sui",
            "0x42",
            Some("0xstate"),
            "challengeSettlement",
            "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            Some(123),
        )
        .unwrap();
        assert_eq!(payload["chain_kind"], "sui");
        assert_eq!(payload["function"], "challenge_settlement");
        assert_eq!(payload["args"][0], "0xstate");
    }
}
