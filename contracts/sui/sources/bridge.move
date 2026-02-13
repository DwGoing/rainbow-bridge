module bridge::bridge {
    use sui::event;
    use sui::table::{Self, Table};

    const E_INTENT_EXISTS: u64 = 1;
    const E_INTENT_NOT_FOUND: u64 = 2;
    const E_INVALID_STATUS: u64 = 3;
    const E_INVALID_SOLVER: u64 = 4;
    const E_INVALID_AMOUNT: u64 = 5;
    const E_VALIDATOR_NOT_ACTIVE: u64 = 6;
    const E_CHALLENGE_WINDOW_NOT_ELAPSED: u64 = 7;
    const E_CHALLENGE_WINDOW_ELAPSED: u64 = 8;
    const E_NOT_PROVIDER: u64 = 9;
    const E_REFUND_NOT_READY: u64 = 10;

    const STATUS_SUBMITTED: u8 = 1;
    const STATUS_EXECUTED: u8 = 2;
    const STATUS_PENDING_SETTLEMENT: u8 = 3;
    const STATUS_SETTLED: u8 = 4;
    const STATUS_REFUNDED: u8 = 5;

    const CHALLENGE_WINDOW_SECS: u64 = 600;

    public struct SwapIntent has store {
        provider: address,
        src_chain_id: u64,
        src_token: vector<u8>,
        src_amount: u64,
        dst_chain_id: u64,
        dst_token: vector<u8>,
        min_dst_amount: u64,
        recipient: vector<u8>,
        deadline: u64,
        nonce: u64,
    }

    public struct IntentRecord has store {
        status: u8,
        solver: address,
    }

    public struct ValidatorInfo has store {
        stake: u64,
        active: bool,
    }

    public struct PendingSettlement has store, drop {
        validator: address,
        solver: address,
        amount_out: u64,
        timestamp: u64,
    }

    public struct BridgeState has key {
        id: UID,
        intents: Table<vector<u8>, SwapIntent>,
        records: Table<vector<u8>, IntentRecord>,
        validators: Table<address, ValidatorInfo>,
        pending_settlements: Table<vector<u8>, PendingSettlement>,
    }

    public struct IntentSubmitted has copy, drop {
        intent_hash: vector<u8>,
        caller: address,
        provider: address,
        src_chain_id: u64,
        src_token: vector<u8>,
        src_amount: u64,
        dst_chain_id: u64,
        dst_token: vector<u8>,
        min_dst_amount: u64,
        recipient: vector<u8>,
        deadline: u64,
        nonce: u64,
    }

    public struct IntentExecuted has copy, drop {
        intent_hash: vector<u8>,
        solver: address,
    }

    public struct SettlementProposed has copy, drop {
        intent_hash: vector<u8>,
        validator: address,
        solver: address,
        amount_out: u64,
    }

    public struct SettlementChallenged has copy, drop {
        intent_hash: vector<u8>,
        challenger: address,
    }

    public struct SettlementFinalized has copy, drop {
        intent_hash: vector<u8>,
        solver: address,
    }

    public struct IntentRefunded has copy, drop {
        intent_hash: vector<u8>,
    }

    public struct ValidatorRegistered has copy, drop {
        validator: address,
        stake: u64,
    }

    fun init(ctx: &mut TxContext) {
        let state = BridgeState {
            id: object::new(ctx),
            intents: table::new(ctx),
            records: table::new(ctx),
            validators: table::new(ctx),
            pending_settlements: table::new(ctx),
        };
        transfer::share_object(state);
    }

    public fun submit_intent(
        state: &mut BridgeState,
        caller: address,
        intent_hash: vector<u8>,
        provider: address,
        src_chain_id: u64,
        src_token: vector<u8>,
        src_amount: u64,
        dst_chain_id: u64,
        dst_token: vector<u8>,
        min_dst_amount: u64,
        recipient: vector<u8>,
        deadline: u64,
        nonce: u64
    ) {
        assert!(!table::contains(&state.intents, copy intent_hash), E_INTENT_EXISTS);

        table::add(
            &mut state.intents,
            copy intent_hash,
            SwapIntent {
                provider,
                src_chain_id,
                src_token,
                src_amount,
                dst_chain_id,
                dst_token,
                min_dst_amount,
                recipient,
                deadline,
                nonce,
            }
        );
        table::add(
            &mut state.records,
            copy intent_hash,
            IntentRecord { status: STATUS_SUBMITTED, solver: @0x0 }
        );

        let submitted = table::borrow(&state.intents, copy intent_hash);
        event::emit(IntentSubmitted {
            intent_hash,
            caller,
            provider: submitted.provider,
            src_chain_id: submitted.src_chain_id,
            src_token: copy submitted.src_token,
            src_amount: submitted.src_amount,
            dst_chain_id: submitted.dst_chain_id,
            dst_token: copy submitted.dst_token,
            min_dst_amount: submitted.min_dst_amount,
            recipient: copy submitted.recipient,
            deadline: submitted.deadline,
            nonce: submitted.nonce,
        });
    }

    public fun execute_intent(
        state: &mut BridgeState,
        intent_hash: vector<u8>,
        solver: address
    ) {
        assert!(solver != @0x0, E_INVALID_SOLVER);
        assert!(table::contains(&state.records, copy intent_hash), E_INTENT_NOT_FOUND);

        let record = table::borrow_mut(&mut state.records, copy intent_hash);
        assert!(record.status == STATUS_SUBMITTED, E_INVALID_STATUS);
        record.status = STATUS_EXECUTED;
        record.solver = solver;

        event::emit(IntentExecuted { intent_hash, solver });
    }

    public fun register_validator(
        state: &mut BridgeState,
        validator: address,
        stake: u64
    ) {
        assert!(stake > 0, E_INVALID_AMOUNT);
        if (table::contains(&state.validators, validator)) {
            let info = table::borrow_mut(&mut state.validators, validator);
            info.stake = info.stake + stake;
            info.active = true;
            event::emit(ValidatorRegistered { validator, stake: info.stake });
        } else {
            table::add(&mut state.validators, validator, ValidatorInfo { stake, active: true });
            event::emit(ValidatorRegistered { validator, stake });
        }
    }

    public fun propose_settlement(
        state: &mut BridgeState,
        validator: address,
        intent_hash: vector<u8>,
        amount_out: u64,
        now_ts: u64
    ) {
        assert!(amount_out > 0, E_INVALID_AMOUNT);
        assert!(table::contains(&state.records, copy intent_hash), E_INTENT_NOT_FOUND);
        assert!(table::contains(&state.validators, validator), E_VALIDATOR_NOT_ACTIVE);
        let v = table::borrow(&state.validators, validator);
        assert!(v.active, E_VALIDATOR_NOT_ACTIVE);

        let record = table::borrow_mut(&mut state.records, copy intent_hash);
        assert!(record.status == STATUS_EXECUTED, E_INVALID_STATUS);
        let solver = record.solver;
        record.status = STATUS_PENDING_SETTLEMENT;

        table::add(
            &mut state.pending_settlements,
            copy intent_hash,
            PendingSettlement {
                validator,
                solver,
                amount_out,
                timestamp: now_ts,
            }
        );

        event::emit(SettlementProposed {
            intent_hash,
            validator,
            solver,
            amount_out,
        });
    }

    public fun challenge_settlement(
        state: &mut BridgeState,
        challenger: address,
        intent_hash: vector<u8>,
        now_ts: u64
    ) {
        assert!(table::contains(&state.records, copy intent_hash), E_INTENT_NOT_FOUND);
        assert!(table::contains(&state.pending_settlements, copy intent_hash), E_INTENT_NOT_FOUND);

        let record = table::borrow_mut(&mut state.records, copy intent_hash);
        assert!(record.status == STATUS_PENDING_SETTLEMENT, E_INVALID_STATUS);
        let pending = table::borrow(&state.pending_settlements, copy intent_hash);
        assert!(now_ts < pending.timestamp + CHALLENGE_WINDOW_SECS, E_CHALLENGE_WINDOW_ELAPSED);
        let validator = pending.validator;

        if (table::contains(&state.validators, validator)) {
            let info = table::borrow_mut(&mut state.validators, validator);
            let slash = info.stake / 10;
            info.stake = info.stake - slash;
            if (info.stake == 0) {
                info.active = false;
            }
        };

        record.status = STATUS_EXECUTED;
        let _ = table::remove(&mut state.pending_settlements, copy intent_hash);
        event::emit(SettlementChallenged { intent_hash, challenger });
    }

    public fun finalize_settlement(
        state: &mut BridgeState,
        intent_hash: vector<u8>,
        now_ts: u64
    ) {
        assert!(table::contains(&state.records, copy intent_hash), E_INTENT_NOT_FOUND);
        assert!(table::contains(&state.pending_settlements, copy intent_hash), E_INTENT_NOT_FOUND);

        let pending = table::borrow(&state.pending_settlements, copy intent_hash);
        assert!(now_ts >= pending.timestamp + CHALLENGE_WINDOW_SECS, E_CHALLENGE_WINDOW_NOT_ELAPSED);
        let solver = pending.solver;

        let record = table::borrow_mut(&mut state.records, copy intent_hash);
        assert!(record.status == STATUS_PENDING_SETTLEMENT, E_INVALID_STATUS);
        record.status = STATUS_SETTLED;

        let _ = table::remove(&mut state.pending_settlements, copy intent_hash);
        event::emit(SettlementFinalized { intent_hash, solver });
    }

    public fun refund_intent(
        state: &mut BridgeState,
        caller: address,
        intent_hash: vector<u8>,
        now_ts: u64
    ) {
        assert!(table::contains(&state.intents, copy intent_hash), E_INTENT_NOT_FOUND);
        assert!(table::contains(&state.records, copy intent_hash), E_INTENT_NOT_FOUND);
        let intent = table::borrow(&state.intents, copy intent_hash);
        assert!(intent.provider == caller, E_NOT_PROVIDER);
        assert!(now_ts > intent.deadline, E_REFUND_NOT_READY);

        let record = table::borrow_mut(&mut state.records, copy intent_hash);
        assert!(record.status == STATUS_SUBMITTED, E_INVALID_STATUS);
        record.status = STATUS_REFUNDED;

        event::emit(IntentRefunded { intent_hash });
    }

    fun destroy_state_for_test(state: BridgeState, intent_hash: vector<u8>, validator: address) {
        let BridgeState {
            id,
            mut intents,
            mut records,
            mut validators,
            mut pending_settlements,
        } = state;

        if (table::contains(&pending_settlements, copy intent_hash)) {
            let PendingSettlement {
                validator: _,
                solver: _,
                amount_out: _,
                timestamp: _,
            } = table::remove(&mut pending_settlements, copy intent_hash);
        };
        if (table::contains(&intents, copy intent_hash)) {
            let SwapIntent {
                provider: _,
                src_chain_id: _,
                src_token: _,
                src_amount: _,
                dst_chain_id: _,
                dst_token: _,
                min_dst_amount: _,
                recipient: _,
                deadline: _,
                nonce: _,
            } = table::remove(&mut intents, copy intent_hash);
        };
        if (table::contains(&records, copy intent_hash)) {
            let IntentRecord { status: _, solver: _ } = table::remove(&mut records, copy intent_hash);
        };
        if (table::contains(&validators, validator)) {
            let ValidatorInfo { stake: _, active: _ } = table::remove(&mut validators, validator);
        };

        table::destroy_empty(pending_settlements);
        table::destroy_empty(intents);
        table::destroy_empty(records);
        table::destroy_empty(validators);
        id.delete();
    }

    #[test]
    fun test_settlement_finalize_flow() {
        let ctx = &mut tx_context::dummy();
        let mut state = BridgeState {
            id: object::new(ctx),
            intents: table::new(ctx),
            records: table::new(ctx),
            validators: table::new(ctx),
            pending_settlements: table::new(ctx),
        };
        let intent_hash = vector[1, 2, 3, 4];

        submit_intent(
            &mut state,
            @0x1,
            copy intent_hash,
            @0x1,
            1,
            vector[0],
            100,
            2,
            vector[1],
            90,
            vector[2],
            1_900_000_000,
            1
        );
        execute_intent(&mut state, copy intent_hash, @0x4);
        register_validator(&mut state, @0x3, 1000);
        propose_settlement(&mut state, @0x3, copy intent_hash, 95, 100);
        finalize_settlement(&mut state, copy intent_hash, 100 + CHALLENGE_WINDOW_SECS);

        let record = table::borrow(&state.records, copy intent_hash);
        assert!(record.status == STATUS_SETTLED, 1001);
        destroy_state_for_test(state, copy intent_hash, @0x3);
    }

    #[test]
    fun test_settlement_challenge_slash_flow() {
        let ctx = &mut tx_context::dummy();
        let mut state = BridgeState {
            id: object::new(ctx),
            intents: table::new(ctx),
            records: table::new(ctx),
            validators: table::new(ctx),
            pending_settlements: table::new(ctx),
        };
        let intent_hash = vector[9, 8, 7, 6];

        submit_intent(
            &mut state,
            @0x1,
            copy intent_hash,
            @0x1,
            1,
            vector[0],
            100,
            2,
            vector[1],
            90,
            vector[2],
            1_900_000_000,
            2
        );
        execute_intent(&mut state, copy intent_hash, @0x4);
        register_validator(&mut state, @0x3, 1000);
        propose_settlement(&mut state, @0x3, copy intent_hash, 95, 200);
        challenge_settlement(&mut state, @0x5, copy intent_hash, 201);

        let record = table::borrow(&state.records, copy intent_hash);
        assert!(record.status == STATUS_EXECUTED, 1002);
        let info = table::borrow(&state.validators, @0x3);
        assert!(info.stake == 900, 1003);
        destroy_state_for_test(state, copy intent_hash, @0x3);
    }
}
