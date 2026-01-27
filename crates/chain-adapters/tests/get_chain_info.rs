use chain_adapters::{ChainAdapter, EvmAdapter, SuiAdapter};

#[tokio::test]
async fn evm_get_block_number() {
    let adapter = EvmAdapter::new("https://ethereum-rpc.publicnode.com");
    let block_num = adapter.get_block_number().await.unwrap();
    println!("EVM Block Number: {}", block_num);

    assert!(block_num > 0);
}

#[tokio::test]
async fn sui_get_block_number() {
    let adapter = SuiAdapter::new("https://fullnode.mainnet.sui.io");
    let block_num = adapter.get_block_number().await.unwrap();
    println!("Sui Block Number: {}", block_num);

    assert!(block_num > 0);
}
