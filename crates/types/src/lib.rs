use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum IntentStatus {
    None,
    Submitted,
    Executed,
    PendingSettlement,
    Settled,
    Refunded,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SwapIntent {
    pub intent_hash: String,
    pub provider: String,
    pub src_chain_id: u64,
    pub src_token: String,
    pub src_amount: u128,
    pub dst_chain_id: u64,
    pub dst_token: String,
    pub min_dst_amount: u128,
    pub recipient: String,
    pub deadline: u64,
    pub nonce: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct IntentSubmittedEvent {
    pub intent: SwapIntent,
    pub tx_hash: String,
    pub block_number: u64,
    pub timestamp: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct IntentSubmissionRef {
    pub intent_hash: String,
    pub caller: String,
    pub tx_hash: String,
    pub block_number: u64,
    pub timestamp: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SettlementProposalRef {
    pub intent_hash: String,
    pub validator: String,
    pub solver: String,
    pub amount_out: u128,
    pub tx_hash: String,
    pub block_number: u64,
    pub timestamp: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExecutionProof {
    pub intent_hash: String,
    pub dst_chain_id: u64,
    pub dst_tx_hash: String,
    pub amount_out: u128,
    pub receiver: String,
    pub solver: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SettlementProposal {
    pub intent_hash: String,
    pub validator: String,
    pub solver: String,
    pub amount_out: u128,
    pub execution_proof: ExecutionProof,
    pub proposed_at: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ValidatorDecision {
    Approve,
    Challenge(String),
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip_settlement_proposal_json() {
        let proposal = SettlementProposal {
            intent_hash: "0xabc".to_string(),
            validator: "0xvalidator".to_string(),
            solver: "0xsolver".to_string(),
            amount_out: 1000,
            execution_proof: ExecutionProof {
                intent_hash: "0xabc".to_string(),
                dst_chain_id: 2,
                dst_tx_hash: "0xdst".to_string(),
                amount_out: 1000,
                receiver: "0xreceiver".to_string(),
                solver: "0xsolver".to_string(),
            },
            proposed_at: 1_725_000_000,
        };

        let serialized = serde_json::to_string(&proposal).unwrap();
        let decoded: SettlementProposal = serde_json::from_str(&serialized).unwrap();
        assert_eq!(decoded, proposal);
    }
}
