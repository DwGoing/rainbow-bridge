use alloy::primitives::{Address, B256, U256, keccak256};
use alloy::providers::{Provider, ProviderBuilder};
use alloy::rpc::types::Filter;
use anyhow::{Result, anyhow};
use async_trait::async_trait;
use std::str::FromStr;
use types::{IntentSubmissionRef, IntentSubmittedEvent, SettlementProposalRef, SwapIntent};

use crate::iadapter::{ChainAdapter, ChainKind};

alloy::sol! {
    #[sol(rpc)]
    interface IEndPointView {
        function intents(bytes32) external view returns (
            address provider,
            address srcToken,
            uint256 srcAmount,
            uint256 dstChainId,
            bytes dstToken,
            uint256 minDstAmount,
            bytes recipient,
            uint256 deadline,
            uint256 nonce,
            bytes permitData
        );
    }

    event SettlementProposed(
        bytes32 indexed intentHash,
        address indexed validator,
        address solver,
        uint256 amountOut
    );
}

pub struct EvmAdapter {
    rpc_url: String,
    endpoint_address: Option<Address>,
}

impl EvmAdapter {
    pub fn new(rpc_url: impl Into<String>) -> Self {
        Self {
            rpc_url: rpc_url.into(),
            endpoint_address: None,
        }
    }

    pub fn new_with_endpoint(rpc_url: impl Into<String>, endpoint_address: Address) -> Self {
        Self {
            rpc_url: rpc_url.into(),
            endpoint_address: Some(endpoint_address),
        }
    }

    async fn get_provider(&self) -> Result<impl Provider> {
        let provider = ProviderBuilder::new().connect_http(self.rpc_url.parse()?);

        Ok(provider)
    }

    fn endpoint_address(&self) -> Result<Address> {
        self.endpoint_address
            .ok_or_else(|| anyhow!("missing endpoint_address for EVM intent polling"))
    }

    fn u256_to_u128(v: U256, field: &str) -> Result<u128> {
        if v > U256::from(u128::MAX) {
            return Err(anyhow!("{field} overflows u128"));
        }
        Ok(v.to::<u128>())
    }

    fn u256_to_u64(v: U256, field: &str) -> Result<u64> {
        if v > U256::from(u64::MAX) {
            return Err(anyhow!("{field} overflows u64"));
        }
        Ok(v.to::<u64>())
    }
}

#[async_trait]
impl ChainAdapter for EvmAdapter {
    fn kind(&self) -> ChainKind {
        ChainKind::Evm
    }

    async fn get_block_number(&self) -> Result<u64> {
        let provider = self.get_provider().await?;
        let block_number = provider.get_block_number().await?;

        Ok(block_number)
    }

    async fn fetch_intent_submissions(
        &self,
        from_block: u64,
        to_block: u64,
    ) -> Result<Vec<IntentSubmissionRef>> {
        let endpoint = self.endpoint_address()?;

        let provider = self.get_provider().await?;
        let topic0: B256 = keccak256("IntentSubmitted(bytes32,address)");
        let filter = Filter::new()
            .address(endpoint)
            .event_signature(topic0)
            .from_block(from_block)
            .to_block(to_block);

        let logs = provider.get_logs(&filter).await?;
        let mut refs = Vec::with_capacity(logs.len());

        for log in logs {
            let topics = log.topics();
            if topics.len() < 3 {
                continue;
            }

            let intent_hash = format!("{:#x}", topics[1]);
            let caller_topic = topics[2];
            let caller = Address::from_slice(&caller_topic.as_slice()[12..]);
            let tx_hash = log
                .transaction_hash
                .map(|v| format!("{:#x}", v))
                .unwrap_or_default();

            refs.push(IntentSubmissionRef {
                intent_hash,
                caller: format!("{:#x}", caller),
                tx_hash,
                block_number: log.block_number.unwrap_or_default(),
                timestamp: log.block_timestamp.unwrap_or_default(),
            });
        }

        Ok(refs)
    }

    async fn fetch_intent_events(
        &self,
        from_block: u64,
        to_block: u64,
    ) -> Result<Vec<IntentSubmittedEvent>> {
        let endpoint = self.endpoint_address()?;
        let submissions = self.fetch_intent_submissions(from_block, to_block).await?;
        let provider = self.get_provider().await?;
        let endpoint_view = IEndPointView::new(endpoint, provider);
        let chain_id = endpoint_view
            .provider()
            .get_chain_id()
            .await
            .map_err(|e| anyhow!("failed to query chain id: {e}"))?;

        let mut events = Vec::with_capacity(submissions.len());
        for submission in submissions {
            let hash = B256::from_str(&submission.intent_hash)
                .map_err(|e| anyhow!("invalid intent hash {}: {e}", submission.intent_hash))?;
            let intent = endpoint_view
                .intents(hash)
                .call()
                .await
                .map_err(|e| anyhow!("failed to fetch intent {}: {e}", submission.intent_hash))?;

            events.push(IntentSubmittedEvent {
                intent: SwapIntent {
                    intent_hash: submission.intent_hash.clone(),
                    provider: format!("{:#x}", intent.provider),
                    src_chain_id: chain_id,
                    src_token: format!("{:#x}", intent.srcToken),
                    src_amount: Self::u256_to_u128(intent.srcAmount, "srcAmount")?,
                    dst_chain_id: Self::u256_to_u64(intent.dstChainId, "dstChainId")?,
                    dst_token: format!("{:#x}", intent.dstToken),
                    min_dst_amount: Self::u256_to_u128(intent.minDstAmount, "minDstAmount")?,
                    recipient: format!("{:#x}", intent.recipient),
                    deadline: Self::u256_to_u64(intent.deadline, "deadline")?,
                    nonce: Self::u256_to_u64(intent.nonce, "nonce")?,
                },
                tx_hash: submission.tx_hash,
                block_number: submission.block_number,
                timestamp: submission.timestamp,
            });
        }

        Ok(events)
    }

    async fn fetch_settlement_proposals(
        &self,
        from_block: u64,
        to_block: u64,
    ) -> Result<Vec<SettlementProposalRef>> {
        let endpoint = self.endpoint_address()?;
        let provider = self.get_provider().await?;
        let topic0: B256 = keccak256("SettlementProposed(bytes32,address,address,uint256)");
        let filter = Filter::new()
            .address(endpoint)
            .event_signature(topic0)
            .from_block(from_block)
            .to_block(to_block);

        let logs = provider.get_logs(&filter).await?;
        let mut proposals = Vec::with_capacity(logs.len());

        for log in logs {
            let topics = log.topics();
            if topics.len() < 3 {
                continue;
            }

            let intent_hash = format!("{:#x}", topics[1]);
            let validator_topic = topics[2];
            let validator_addr = Address::from_slice(&validator_topic.as_slice()[12..]);

            let decoded = log
                .log_decode::<SettlementProposed>()
                .map_err(|e| anyhow!("failed to decode SettlementProposed log: {e}"))?;
            let data = decoded.data();

            proposals.push(SettlementProposalRef {
                intent_hash,
                validator: format!("{:#x}", validator_addr),
                solver: format!("{:#x}", data.solver),
                amount_out: Self::u256_to_u128(data.amountOut, "amountOut")?,
                tx_hash: log
                    .transaction_hash
                    .map(|v| format!("{:#x}", v))
                    .unwrap_or_default(),
                block_number: log.block_number.unwrap_or_default(),
                timestamp: log.block_timestamp.unwrap_or_default(),
            });
        }

        Ok(proposals)
    }
}
