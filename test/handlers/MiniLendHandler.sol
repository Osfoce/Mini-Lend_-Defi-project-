// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MiniLend} from "../../src/contracts/MiniLend.sol";
import {Test} from "forge-std/Test.sol";

contract MiniLendHandler is Test {
    MiniLend public miniLend;

    address[] public users;
    address public borrowToken;

    constructor(MiniLend _miniLend, address _borrowToken) {
        miniLend = _miniLend;
        borrowToken = _borrowToken;

        // Create simulated users
        for (uint256 i = 0; i < 5; i++) {
            address user = address(uint160(uint256(keccak256(abi.encode(i)))));
            users.push(user);

            vm.deal(user, 100 ether);
        }
    }

    /* ========== ACTIONS (Foundry calls these randomly) ========== */

    function stakeEth(uint256 userIndex, uint256 amount) public {
        address user = users[userIndex % users.length];

        amount = bound(amount, 0.1 ether, 10 ether);

        vm.prank(user);
        miniLend.stakeEth{value: amount}();
    }

    function borrow(uint256 userIndex, uint256 amount) public {
        address user = users[userIndex % users.length];

        amount = bound(amount, 1e18, 1000e18);

        vm.prank(user);
        try miniLend.borrowAsset(borrowToken, amount) {} catch {}
    }

    function repay(uint256 userIndex, uint256 amount) public {
        address user = users[userIndex % users.length];

        amount = bound(amount, 1e18, 1000e18);

        vm.prank(user);
        try miniLend.repayAsset(borrowToken, amount) {} catch {}
    }

    function withdraw(uint256 userIndex, uint256 amount) public {
        address user = users[userIndex % users.length];

        amount = bound(amount, 0.1 ether, 10 ether);

        vm.prank(user);
        try miniLend.withdrawCollateralEth(amount) {} catch {}
    }
}
