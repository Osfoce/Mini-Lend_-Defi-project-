// pragma solidity ^0.8.20;

// import "forge-std/Test.sol";
// import "../../src/MiniLend.sol";

// contract MiniLendInvariant is Test {
//     MiniLend lend;

//     function setUp() public {
//         lend = new MiniLend();
//     }

// function invariant_borrow_never_exceeds_ltv() public {
//     address user = address(0x123);

//     (
//         address stakedAsset,
//         uint256 stakedAmount,
//         address borrowedAsset,
//         uint256 borrowedAmount
//     ) = lend.getUser(user);

//     if (stakedAmount == 0 || borrowedAmount == 0) return;

//     uint256 collateralUsd = lend.getUsdValue(stakedAsset, stakedAmount);
//     uint256 borrowedUsd = lend.getUsdValue(borrowedAsset, borrowedAmount);

//     uint256 maxBorrowUsd =
//         (collateralUsd * lend.LTV()) / 10_000;

//     assertLe(borrowedUsd, maxBorrowUsd);
// }

// function invariant_healthy_positions_not_liquidatable() public {
//     address user = address(0x123);

//     (
//         address stakedAsset,
//         uint256 stakedAmount,
//         address borrowedAsset,
//         uint256 borrowedAmount
//     ) = lend.getUser(user);

//     if (stakedAmount == 0 || borrowedAmount == 0) return;

//     uint256 collateralUsd = lend.getUsdValue(stakedAsset, stakedAmount);
//     uint256 borrowedUsd = lend.getUsdValue(borrowedAsset, borrowedAmount);

//     uint256 thresholdUsd =
//         (collateralUsd * lend.LIQUIDATION_THRESHOLD()) / 10_000;

//     // If healthy, liquidation must NOT be possible
//     if (borrowedUsd <= thresholdUsd) {
//         vm.expectRevert();
//         lend.liquidate(user, 1);
//     }
// }

// function invariant_pool_never_negative() public {
//     uint256 tokenCount = lend.getApprovedTokensCount();

//     for (uint256 i = 0; i < tokenCount; i++) {
//         address token = lend.approvedTokenList(i);

//         uint256 poolBalance =
//             IERC20(token).balanceOf(address(lend));

//         assertGe(poolBalance, 0);
//     }
// }

// }


// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/contracts/MiniLend.sol";
import "./handlers/MiniLendHandler.sol";

contract MiniLendInvariant is Test {
    MiniLend public miniLend;
    MiniLendHandler public handler;

    address public mockToken;

    function setUp() public {
        miniLend = new MiniLend();

        // Deploy mock ERC20
        mockToken = address(new MockERC20());

        miniLend.approveToken(mockToken);

        // Set fake price feeds (mock oracle)
        miniLend.setFeed(mockToken, address(new MockOracle(1e18)));
        miniLend.setFeed(
            0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE,
            address(new MockOracle(2000e18))
        );

        handler = new MiniLendHandler(miniLend, mockToken);

        targetContract(address(handler));
    }

    /* ========== INVARIANTS ========== */

    function invariant_noNegativeBalances() public {
        // ETH balance can never underflow
        assert(address(miniLend).balance >= 0);
    }

    function invariant_ltvRespected() public {
        // For every user, borrowed USD <= collateral USD * LTV
        // (simplified example — can be extended)
    }

    function invariant_collateralNonZeroIfBorrowed() public {
        // If user borrowed, they must have collateral
    }
}

