use anyhow::Result;
use async_trait::async_trait;
use types::{IntentSubmissionRef, IntentSubmittedEvent, SettlementProposalRef};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ChainKind {
    Evm,
    Sui,
}

#[async_trait]
pub trait ChainAdapter: Send + Sync {
    fn kind(&self) -> ChainKind;
    async fn get_block_number(&self) -> Result<u64>;

    async fn fetch_intent_submissions(
        &self,
        _from_block: u64,
        _to_block: u64,
    ) -> Result<Vec<IntentSubmissionRef>> {
        Ok(Vec::new())
    }

    async fn fetch_intent_events(
        &self,
        _from_block: u64,
        _to_block: u64,
    ) -> Result<Vec<IntentSubmittedEvent>> {
        Ok(Vec::new())
    }

    async fn fetch_settlement_proposals(
        &self,
        _from_block: u64,
        _to_block: u64,
    ) -> Result<Vec<SettlementProposalRef>> {
        Ok(Vec::new())
    }
}
