// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

enum IntentStatus {
    None,
    Submitted,
    Executed,
    PendingSettlement,
    Settled,
    Refunded
}
