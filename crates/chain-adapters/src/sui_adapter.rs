use anyhow::Result;
use async_trait::async_trait;
use sui_sdk::{SuiClient, SuiClientBuilder};

use crate::iadapter::{ChainAdapter, ChainKind};

pub struct SuiAdapter {
    rpc_url: String,
}

impl SuiAdapter {
    pub fn new(rpc_url: impl Into<String>) -> Self {
        Self {
            rpc_url: rpc_url.into(),
        }
    }

    async fn get_client(&self) -> Result<SuiClient> {
        let client = SuiClientBuilder::default()
            .build(self.rpc_url.clone())
            .await?;

        Ok(client)
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
}
