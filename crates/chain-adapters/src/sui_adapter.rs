use anyhow::{Result, anyhow};
use async_trait::async_trait;
use move_core_types::identifier::Identifier;
use serde_json::Value;
use std::str::FromStr;
use sui_sdk::rpc_types::EventFilter;
use sui_sdk::types::base_types::ObjectID;
use sui_sdk::{SuiClient, SuiClientBuilder};
use types::{IntentSubmissionRef, IntentSubmittedEvent, SettlementProposalRef, SwapIntent};

use crate::iadapter::{ChainAdapter, ChainKind};

pub struct SuiAdapter {
    rpc_url: String,
    package_id: Option<String>,
    module: String,
}

impl SuiAdapter {
    pub fn new(rpc_url: impl Into<String>) -> Self {
        Self {
            rpc_url: rpc_url.into(),
            package_id: None,
            module: "bridge".to_string(),
        }
    }

    pub fn new_with_module(
        rpc_url: impl Into<String>,
        package_id: Option<String>,
        module: impl Into<String>,
    ) -> Self {
        Self {
            rpc_url: rpc_url.into(),
            package_id,
            module: module.into(),
        }
    }

    async fn get_client(&self) -> Result<SuiClient> {
        let client = SuiClientBuilder::default()
            .build(self.rpc_url.clone())
            .await?;

        Ok(client)
    }

    fn package_id(&self) -> Result<ObjectID> {
        self.package_id
            .as_ref()
            .and_then(|v| ObjectID::from_str(v).ok())
            .ok_or_else(|| anyhow!("missing package_id for Sui event polling"))
    }

    fn parse_u64(v: &Value, field: &str) -> Result<u64> {
        match v {
            Value::Number(n) => n
                .as_u64()
                .ok_or_else(|| anyhow!("{field} is not a valid u64 number")),
            Value::String(s) => s
                .parse::<u64>()
                .map_err(|e| anyhow!("invalid {field} '{s}': {e}")),
            _ => Err(anyhow!("invalid json type for {field}")),
        }
    }

    fn parse_u128(v: &Value, field: &str) -> Result<u128> {
        match v {
            Value::Number(n) => n
                .as_u64()
                .map(u128::from)
                .ok_or_else(|| anyhow!("{field} is not a valid u128 number")),
            Value::String(s) => s
                .parse::<u128>()
                .map_err(|e| anyhow!("invalid {field} '{s}': {e}")),
            _ => Err(anyhow!("invalid json type for {field}")),
        }
    }

    fn parse_address(v: Option<&Value>) -> String {
        v.and_then(|x| x.as_str())
            .map(ToString::to_string)
            .unwrap_or_default()
    }

    fn parse_bytes_hex(v: Option<&Value>) -> String {
        let Some(value) = v else {
            return "0x".to_string();
        };
        if let Some(s) = value.as_str() {
            if s.starts_with("0x") {
                return s.to_string();
            }
            return format!("0x{}", alloy::hex::encode(s.as_bytes()));
        }
        if let Some(arr) = value.as_array() {
            let mut bytes = Vec::with_capacity(arr.len());
            for b in arr {
                if let Some(x) = b.as_u64() {
                    bytes.push((x & 0xff) as u8);
                }
            }
            return format!("0x{}", alloy::hex::encode(bytes));
        }
        "0x".to_string()
    }

    fn event_tx_hash(event: &sui_sdk::rpc_types::SuiEvent) -> String {
        format!("{:#x}", event.id.tx_digest)
    }
}

#[async_trait]
impl ChainAdapter for SuiAdapter {
    fn kind(&self) -> ChainKind {
        ChainKind::Sui
    }

    async fn get_block_number(&self) -> Result<u64> {
        let client = self.get_client().await?;
        let block_number = client.read_api().get_total_transaction_blocks().await?;

        Ok(block_number)
    }

    async fn fetch_intent_submissions(
        &self,
        from_block: u64,
        to_block: u64,
    ) -> Result<Vec<IntentSubmissionRef>> {
        let client = self.get_client().await?;
        let package = self.package_id()?;
        let module =
            Identifier::from_str(&self.module).map_err(|e| anyhow!("invalid module name: {e}"))?;
        let filter = EventFilter::MoveModule { package, module };
        let page = client
            .event_api()
            .query_events(filter, None, Some(200), false)
            .await?;

        let mut out = Vec::new();
        for event in page.data {
            let type_name = format!("{}", event.type_.name);
            if type_name != "IntentSubmitted" {
                continue;
            }
            if event.id.event_seq < from_block || event.id.event_seq > to_block {
                continue;
            }
            let parsed = event
                .parsed_json
                .as_object()
                .ok_or_else(|| anyhow!("invalid parsed_json for IntentSubmitted"))?;

            let intent_hash = Self::parse_bytes_hex(parsed.get("intent_hash"));
            out.push(IntentSubmissionRef {
                intent_hash,
                caller: Self::parse_address(parsed.get("caller")),
                tx_hash: Self::event_tx_hash(&event),
                block_number: event.id.event_seq,
                timestamp: event.timestamp_ms.unwrap_or_default() / 1000,
            });
        }

        Ok(out)
    }

    async fn fetch_intent_events(
        &self,
        from_block: u64,
        to_block: u64,
    ) -> Result<Vec<IntentSubmittedEvent>> {
        let client = self.get_client().await?;
        let package = self.package_id()?;
        let module =
            Identifier::from_str(&self.module).map_err(|e| anyhow!("invalid module name: {e}"))?;
        let filter = EventFilter::MoveModule { package, module };
        let page = client
            .event_api()
            .query_events(filter, None, Some(200), false)
            .await?;

        let mut out = Vec::new();
        for event in page.data {
            let type_name = format!("{}", event.type_.name);
            if type_name != "IntentSubmitted" {
                continue;
            }
            if event.id.event_seq < from_block || event.id.event_seq > to_block {
                continue;
            }
            let parsed = event
                .parsed_json
                .as_object()
                .ok_or_else(|| anyhow!("invalid parsed_json for IntentSubmitted"))?;

            let intent_hash = Self::parse_bytes_hex(parsed.get("intent_hash"));
            let src_chain_id = Self::parse_u64(
                parsed
                    .get("src_chain_id")
                    .ok_or_else(|| anyhow!("missing src_chain_id"))?,
                "src_chain_id",
            )?;
            let dst_chain_id = Self::parse_u64(
                parsed
                    .get("dst_chain_id")
                    .ok_or_else(|| anyhow!("missing dst_chain_id"))?,
                "dst_chain_id",
            )?;
            let src_amount = Self::parse_u128(
                parsed
                    .get("src_amount")
                    .ok_or_else(|| anyhow!("missing src_amount"))?,
                "src_amount",
            )?;
            let min_dst_amount = Self::parse_u128(
                parsed
                    .get("min_dst_amount")
                    .ok_or_else(|| anyhow!("missing min_dst_amount"))?,
                "min_dst_amount",
            )?;
            let deadline = Self::parse_u64(
                parsed
                    .get("deadline")
                    .ok_or_else(|| anyhow!("missing deadline"))?,
                "deadline",
            )?;
            let nonce = Self::parse_u64(
                parsed
                    .get("nonce")
                    .ok_or_else(|| anyhow!("missing nonce"))?,
                "nonce",
            )?;

            out.push(IntentSubmittedEvent {
                intent: SwapIntent {
                    intent_hash,
                    provider: Self::parse_address(parsed.get("provider")),
                    src_chain_id,
                    src_token: Self::parse_bytes_hex(parsed.get("src_token")),
                    src_amount,
                    dst_chain_id,
                    dst_token: Self::parse_bytes_hex(parsed.get("dst_token")),
                    min_dst_amount,
                    recipient: Self::parse_bytes_hex(parsed.get("recipient")),
                    deadline,
                    nonce,
                },
                tx_hash: Self::event_tx_hash(&event),
                block_number: event.id.event_seq,
                timestamp: event.timestamp_ms.unwrap_or_default() / 1000,
            });
        }

        Ok(out)
    }

    async fn fetch_settlement_proposals(
        &self,
        from_block: u64,
        to_block: u64,
    ) -> Result<Vec<SettlementProposalRef>> {
        let client = self.get_client().await?;
        let package = self.package_id()?;
        let module =
            Identifier::from_str(&self.module).map_err(|e| anyhow!("invalid module name: {e}"))?;
        let filter = EventFilter::MoveModule { package, module };
        let page = client
            .event_api()
            .query_events(filter, None, Some(200), false)
            .await?;

        let mut out = Vec::new();
        for event in page.data {
            let type_name = format!("{}", event.type_.name);
            if type_name != "SettlementProposed" {
                continue;
            }
            if event.id.event_seq < from_block || event.id.event_seq > to_block {
                continue;
            }
            let parsed = event
                .parsed_json
                .as_object()
                .ok_or_else(|| anyhow!("invalid parsed_json for SettlementProposed"))?;

            let amount_out = Self::parse_u128(
                parsed
                    .get("amount_out")
                    .ok_or_else(|| anyhow!("missing amount_out"))?,
                "amount_out",
            )?;
            out.push(SettlementProposalRef {
                intent_hash: Self::parse_bytes_hex(parsed.get("intent_hash")),
                validator: Self::parse_address(parsed.get("validator")),
                solver: Self::parse_address(parsed.get("solver")),
                amount_out,
                tx_hash: Self::event_tx_hash(&event),
                block_number: event.id.event_seq,
                timestamp: event.timestamp_ms.unwrap_or_default() / 1000,
            });
        }

        Ok(out)
    }
}
