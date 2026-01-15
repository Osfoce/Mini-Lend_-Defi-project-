// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MiniLend} from "../../src/contracts/MiniLend.sol";
import {Test} from "forge-std/Test.sol";

contract MiniLendHandler is Test {
    MiniLend public miniLend;
    address public borrowToken;

    address[] public users;

    // ===== STATE TRACKING =====
    mapping(address => uint256) public lastDebt;
    mapping(address => uint256) public lastCollateral;

    constructor(MiniLend _miniLend, address _borrowToken) {
        miniLend = _miniLend;
        borrowToken = _borrowToken;

        for (uint256 i = 0; i < 5; i++) {
            address user = address(uint160(uint256(keccak256(abi.encode(i)))));
            users.push(user);
            vm.deal(user, 100 ether);
        }
    }

    function stakeEth(uint256 userIndex, uint256 amount) public {
        address user = users[userIndex % users.length];
        amount = bound(amount, 0.1 ether, 10 ether);

        vm.prank(user);
        miniLend.stakeEth{value: amount}();

        (, uint256 staked, , ) = miniLend.getUser(user);
        lastCollateral[user] = staked;
    }

    function borrow(uint256 userIndex, uint256 amount) public {
        address user = users[userIndex % users.length];
        amount = bound(amount, 1e18, 1000e18);

        (, , , uint256 beforeDebt) = miniLend.getUser(user);

        vm.prank(user);
        try miniLend.borrowAsset(borrowToken, amount) {} catch {}

        (, , , uint256 afterDebt) = miniLend.getUser(user);

        // STATEFUL invariant: debt only increases here
        assert(afterDebt >= beforeDebt);
        lastDebt[user] = afterDebt;
    }

    function repay(uint256 userIndex, uint256 amount) public {
        address user = users[userIndex % users.length];
        amount = bound(amount, 1e18, 1000e18);

        (, , , uint256 beforeDebt) = miniLend.getUser(user);

        vm.prank(user);
        try miniLend.repayAsset(borrowToken, amount) {} catch {}

        (, , , uint256 afterDebt) = miniLend.getUser(user);

        // STATEFUL invariant: repay never increases debt
        assert(afterDebt <= beforeDebt);
        lastDebt[user] = afterDebt;
    }

    function withdraw(uint256 userIndex, uint256 amount) public {
        address user = users[userIndex % users.length];
        amount = bound(amount, 0.1 ether, 10 ether);

        (, uint256 beforeCollateral, , uint256 debt) = miniLend.getUser(user);

        vm.prank(user);
        try miniLend.withdrawCollateralEth(amount) {} catch {}

        (, uint256 afterCollateral, , ) = miniLend.getUser(user);

        // If debt exists, collateral must not decrease
        if (debt > 0) {
            assert(afterCollateral >= beforeCollateral);
        }

        lastCollateral[user] = afterCollateral;
    }

    function liquidate(
        uint256 liquidatorIndex,
        uint256 borrowerIndex,
        uint256 amount
    ) public {
        address liquidator = users[liquidatorIndex % users.length];
        address borrower = users[borrowerIndex % users.length];

        amount = bound(amount, 1e18, 500e18);

        vm.prank(liquidator);
        try miniLend.liquidate(borrower, amount) {} catch {}
    }

    function getUsers() external view returns (address[] memory) {
        return users;
    }

    function usersLength() external view returns (uint256) {
        return users.length;
    }
}
