use solver::build_proposal;
use types::{IntentSubmittedEvent, SwapIntent, ValidatorDecision};
use validator::validate_proposal;

#[test]
fn e2e_solver_to_validator_approve() {
    let event = IntentSubmittedEvent {
        intent: SwapIntent {
            intent_hash: "0xintent".to_string(),
            provider: "0xprovider".to_string(),
            src_chain_id: 1,
            src_token: "0xsrc".to_string(),
            src_amount: 1_000,
            dst_chain_id: 2,
            dst_token: "0xdst".to_string(),
            min_dst_amount: 900,
            recipient: "0xreceiver".to_string(),
            deadline: 1_900_000_000,
            nonce: 1,
        },
        tx_hash: "0xtx".to_string(),
        block_number: 123,
        timestamp: 1_700_000_000,
    };

    let proposal = build_proposal(&event, "0xsolver", "0xvalidator", 900).unwrap();
    let decision = validate_proposal(&proposal);
    assert!(matches!(decision, ValidatorDecision::Approve));
}
