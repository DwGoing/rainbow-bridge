use alloy::providers::{Provider, ProviderBuilder};
use anyhow::Result;
use async_trait::async_trait;

use crate::iadapter::ChainAdapter;

pub struct EvmAdapter {
    rpc_url: String,
}

impl EvmAdapter {
    pub fn new(rpc_url: impl Into<String>) -> Self {
        Self {
            rpc_url: rpc_url.into(),
        }
    }

    async fn get_provider(&self) -> Result<impl Provider> {
        let provider = ProviderBuilder::new().connect_http(self.rpc_url.parse()?);

        Ok(provider)
    }
}

#[async_trait]
impl ChainAdapter for EvmAdapter {
    async fn get_block_number(&self) -> Result<u64> {
        let provider = self.get_provider().await?;
        let block_number = provider.get_block_number().await?;

        Ok(block_number)
    }
}
