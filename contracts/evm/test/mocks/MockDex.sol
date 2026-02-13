// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract MockDex {
    using SafeERC20 for IERC20;

    function swap(
        address srcToken,
        address dstToken,
        uint256 amount,
        uint256 rate, // 10000 = 1:1
        address receipient
    ) external returns (uint256) {
        IERC20(srcToken).safeTransferFrom(msg.sender, address(this), amount);
        uint256 dstAmount = (amount * rate) / 10000;
        IERC20(dstToken).safeTransfer(receipient, dstAmount);
        return dstAmount;
    }
}
