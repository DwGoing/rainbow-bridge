use anyhow::{Result, anyhow};
use std::time::{SystemTime, UNIX_EPOCH};
use types::{ExecutionProof, IntentSubmittedEvent, SettlementProposal};

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
}
