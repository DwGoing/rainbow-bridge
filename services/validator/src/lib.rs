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
}
