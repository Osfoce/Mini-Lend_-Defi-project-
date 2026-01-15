// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MiniLend} from "../src/contracts/MiniLend.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAggregator} from "./mocks/MockAggregator.sol";

contract MiniLendTest is Test {
    MiniLend lend;
    MockERC20 usdc;
    MockAggregator ethFeed;
    MockAggregator usdcFeed;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        lend = new MiniLend();

        usdc = new MockERC20("USDC", "USDC", 18);
        ethFeed = new MockAggregator(2000e8);
        usdcFeed = new MockAggregator(1e8);

        // Prices
        // ethFeed.setPrice(2000e8); // ETH = $2000
        // usdcFeed.setPrice(1e8); // USDC = $1

        lend.setFeed(lend.ETH_ADDRESS(), address(ethFeed));
        lend.setFeed(address(usdc), address(usdcFeed));

        lend.approveToken(address(usdc));

        usdc.mint(address(lend), 1_000_000e18);
        usdc.mint(alice, 100_000e18);

        vm.deal(alice, 100 ether);
    }

    function testStakeEth() public {
        vm.prank(alice);
        lend.stakeEth{value: 10 ether}();

        (, uint256 staked, , ) = lend.getUser(alice);
        assertEq(staked, 10 ether);
    }

    function testBorrowWithinLtv() public {
        vm.startPrank(alice);
        lend.stakeEth{value: 10 ether}();

        // 10 ETH * $2000 = $20,000
        // LTV 50% => $10,000 max borrow
        lend.borrowAsset(address(usdc), 10_000e18);
        vm.stopPrank();

        (, , , uint256 borrowed) = lend.getUser(alice);
        assertEq(borrowed, 10_000e18);
    }

    function testBorrowOverLtvReverts() public {
        vm.startPrank(alice);
        lend.stakeEth{value: 10 ether}();

        vm.expectRevert();
        lend.borrowAsset(address(usdc), 17_000e18);
        vm.stopPrank();
    }

    function testRepay() public {
        vm.startPrank(alice);
        lend.stakeEth{value: 10 ether}();
        lend.borrowAsset(address(usdc), 5_000e18);

        usdc.approve(address(lend), 5_000e18);
        lend.repayAsset(address(usdc), 5_000e18);
        vm.stopPrank();

        (, , , uint256 borrowed) = lend.getUser(alice);
        assertEq(borrowed, 0);
    }

    function testWithdrawCollateralEth() public {
        vm.startPrank(alice);
        lend.stakeEth{value: 10 ether}();
        lend.withdrawCollateralEth(9.5 ether);
        vm.stopPrank();

        (, uint256 staked, , ) = lend.getUser(alice);
        assertEq(staked, 0.5 ether);
    }

    function testLiquidationWorks() public {
        vm.startPrank(alice);
        lend.stakeEth{value: 10 ether}();
        lend.borrowAsset(address(usdc), 9_000e18);
        vm.stopPrank();

        // ETH price crashes to $1000
        // ethFeed = new MockAggregator(1000e8);
        ethFeed.setPrice(1000e8);

        usdc.mint(bob, 5_000e18);
        vm.startPrank(bob);
        usdc.approve(address(lend), 5_000e18);

        lend.liquidate(alice, 5_000e18);
        vm.stopPrank();

        (, uint256 staked, , ) = lend.getUser(alice);
        assertLt(staked, 10 ether);
    }

    function testLiquidatorOverpaysWhenCollateralIsInsufficient() public {
        // Alice deposits small collateral
        vm.startPrank(alice);
        lend.stakeEth{value: 1 ether}(); // ~$2000
        lend.borrowAsset(address(usdc), 1_000e18);
        vm.stopPrank();

        // ETH price crashes hard
        // ethFeed = new MockAggregator(500e8);
        ethFeed.setPrice(500e8); // $500

        // Bob prepares to liquidate
        usdc.mint(bob, 1_000e18);
        vm.startPrank(bob);
        usdc.approve(address(lend), type(uint256).max);

        uint256 bobBalanceBefore = usdc.balanceOf(bob);

        lend.liquidate(alice, 1_000e18);

        uint256 bobBalanceAfter = usdc.balanceOf(bob);
        vm.stopPrank();

        // BUG: Bob paid full repay but got less collateral value
        uint256 repaid = bobBalanceBefore - bobBalanceAfter;

        assertGt(repaid, 0);
        assertLt(
            address(bob).balance,
            1 ether,
            "Liquidator overpaid and got capped collateral"
        );
    }
}
