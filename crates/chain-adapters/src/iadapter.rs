use anyhow::Result;
use async_trait::async_trait;

#[async_trait]
pub trait ChainAdapter {
    async fn get_block_number(&self) -> Result<u64>;
}
