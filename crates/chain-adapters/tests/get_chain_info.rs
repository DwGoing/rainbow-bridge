use chain_adapters::{ChainAdapter, EvmAdapter, SuiAdapter};

fn run_network_tests() -> bool {
    std::env::var("RUN_NETWORK_TESTS")
        .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
        .unwrap_or(false)
}

#[tokio::test]
async fn evm_get_block_number() {
    if !run_network_tests() {
        eprintln!("skip evm_get_block_number: set RUN_NETWORK_TESTS=true to enable");
        return;
    }

    let adapter = EvmAdapter::new("https://ethereum-rpc.publicnode.com");
    let block_num = adapter.get_block_number().await.unwrap();
    println!("EVM Block Number: {}", block_num);

    assert!(block_num > 0);
}

#[tokio::test]
async fn sui_get_block_number() {
    if !run_network_tests() {
        eprintln!("skip sui_get_block_number: set RUN_NETWORK_TESTS=true to enable");
        return;
    }

    let adapter = SuiAdapter::new("https://fullnode.mainnet.sui.io");
    let block_num = adapter.get_block_number().await.unwrap();
    println!("Sui Block Number: {}", block_num);

    assert!(block_num > 0);
}
