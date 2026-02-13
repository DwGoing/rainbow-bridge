module bridge::bridge {
    use std::string::String;
    use sui::event;

    public struct IntentSubmitted has copy, drop {
        intent_hash: vector<u8>,
        caller: address,
        metadata: String,
    }

    public entry fun emit_intent_submitted(
        caller: address,
        intent_hash: vector<u8>,
        metadata: String
    ) {
        event::emit(IntentSubmitted {
            intent_hash,
            caller,
            metadata,
        });
    }
}
