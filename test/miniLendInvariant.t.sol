// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/contracts/MiniLend.sol";
import "./handlers/MiniLendHandler.sol";
import "./mocks/MockERC20.sol";
import "./mocks/MockAggregator.sol";

contract MiniLendInvariant is Test {
    MiniLend public miniLend;
    // MockERC20 public mockToken;
    MiniLendHandler public handler;

    address public mockToken;

    function setUp() public {
        miniLend = new MiniLend();

        mockToken = address(new MockERC20("Mock USD", "mUSD", 18));

        miniLend.approveToken(mockToken);
        miniLend.setFeed(mockToken, address(new MockAggregator(1e18)));
        miniLend.setFeed(
            0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE,
            address(new MockAggregator(2000e18))
        );

        handler = new MiniLendHandler(miniLend, mockToken);
        targetContract(address(handler));
    }

    /* ========== STATELESS INVARIANTS ========== */

    function invariant_ethBalanceCoversAllCollateral() public view {
        uint256 totalStaked;
        uint256 len = handler.usersLength();

        for (uint256 i = 0; i < len; i++) {
            address user = handler.users(i);
            (, uint256 staked, , ) = miniLend.getUser(user);
            totalStaked += staked;
        }

        assertGe(address(miniLend).balance, totalStaked);
    }

    function invariant_noDebtWithoutCollateral() public view {
        uint256 len = handler.usersLength();

        for (uint256 i = 0; i < len; i++) {
            (, uint256 staked, , uint256 debt) = miniLend.getUser(
                handler.users(i)
            );
            if (debt > 0) {
                assert(staked > 0);
            }
        }
    }

    function invariant_contractSolventForBorrowedToken() public view {
        uint256 totalDebt;
        uint256 len = handler.usersLength();

        for (uint256 i = 0; i < len; i++) {
            (, , , uint256 debt) = miniLend.getUser(handler.users(i));
            totalDebt += debt;
        }

        uint256 balance = IERC20(mockToken).balanceOf(address(miniLend));
        assert(balance >= totalDebt);
    }
}
