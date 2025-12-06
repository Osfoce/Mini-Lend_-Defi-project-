// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*
  MiniLendRefactored.sol

  - Fixed-point math using WAD = 1e18
  - Uses a pluggable price oracle (returns ETH price in USD with 18 decimals)
  - Public borrow & repay functions
  - Partial collateral withdrawals allowed if post-withdraw health is ok
  - Liquidation by third-parties with a liquidation bonus (BPS)
  - Uses IERC20 for USD token; supports mint-on-shortfall if token exposes mint()
  - Clear custom errors, events, and admin setters
*/

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Address.sol";

interface IPriceOracle {
    /// @notice returns ETH price in USD with 18 decimals (e.g., 2000 * 1e18)
    function getLatestPrice() external view returns (uint256);
}

interface IMintableERC20 is IERC20 {
    function mint(address to, uint256 amount) external returns (bool);
}

contract MiniLendRefactored is ReentrancyGuard, Ownable(msg.sender) {
    using Address for address payable;

    /* ============ Errors ============ */
    error InvalidAddress(address addr);
    error InvalidAmount();
    error NoCollateralProvided();
    error BorrowLimitExceeded(uint256 requested, uint256 available);
    error BorrowedAmountNotFullyRepaid(uint256 outstanding);
    error NotEnoughCollateral(uint256 available, uint256 requested);
    error OverPaymentNotSupported(uint256 paid, uint256 outstanding);
    error InsufficientPoolFunds(uint256 required, uint256 available);
    error LoanNotFound();
    error NotLiquidatable(uint256 healthFactor);
    error TransferFailed();
    error UnsupportedToken();

    /* ============ Events ============ */
    event EthStaked(address indexed user, uint256 ethAmount);
    event USDBorrowed(address indexed user, uint256 usdAmount);
    event USDRepaid(address indexed user, uint256 usdAmount);
    event ETHCollateralWithdrawn(address indexed user, uint256 ethAmount);
    event Liquidation(
        address indexed liquidator,
        address indexed borrower,
        uint256 repayAmount,
        uint256 seizedEth
    );
    event OracleUpdated(address indexed newOracle);
    event USDTokenUpdated(address indexed newToken);
    event LtvUpdated(uint256 newLtv);
    event LiquidationBonusUpdated(uint256 newBonusBps);

    /* ============ Structs ============ */
    struct User {
        uint256 stakedEth; // wei
        uint256 borrowedUsd; // 18 decimals (USD with 1e18)
    }

    /* ============ State ============ */
    mapping(address => User) public users;

    IERC20 public usdToken; // USD-like ERC20 (18 decimals expected)
    IPriceOracle public priceOracle; // returns ETH price in USD (18 decimals)

    uint256 public constant WAD = 1e18;
    uint256 public constant PCT_DENOMINATOR = 100; // percent denom (100)
    uint256 public constant BPS_DENOMINATOR = 10000; // bps denom

    uint256 public ltvPct = 50; // LTV in percent (50 = 50%)
    uint256 public liquidationThresholdPct = 75; // percent at which liquidation allowed
    uint256 public liquidationBonusBps = 500; // 5% bonus to liquidator (bps)

    /* ============ Constructor ============ */
    constructor(address _usdToken, address _priceOracle) {
        if (_usdToken == address(0) || _priceOracle == address(0))
            revert InvalidAddress(address(0));
        usdToken = IERC20(_usdToken);
        priceOracle = IPriceOracle(_priceOracle);
    }

    /* ============ Admin Setters ============ */
    function setPriceOracle(address _oracle) external onlyOwner {
        if (_oracle == address(0)) revert InvalidAddress(_oracle);
        priceOracle = IPriceOracle(_oracle);
        emit OracleUpdated(_oracle);
    }

    function setUsdToken(address _usd) external onlyOwner {
        if (_usd == address(0)) revert InvalidAddress(_usd);
        usdToken = IERC20(_usd);
        emit USDTokenUpdated(_usd);
    }

    function setLtv(uint256 _ltvPct) external onlyOwner {
        require(_ltvPct <= PCT_DENOMINATOR, "bad ltv");
        ltvPct = _ltvPct;
        emit LtvUpdated(_ltvPct);
    }

    function setLiquidationBonus(uint256 _bonusBps) external onlyOwner {
        require(_bonusBps <= BPS_DENOMINATOR, "bad bps");
        liquidationBonusBps = _bonusBps;
        emit LiquidationBonusUpdated(_bonusBps);
    }

    /* ============ Public Actions ============ */

    /// @notice Stake ETH as collateral
    function stakeEth() external payable nonReentrant {
        if (msg.value == 0) revert NoCollateralProvided();
        users[msg.sender].stakedEth += msg.value;
        emit EthStaked(msg.sender, msg.value);
    }

    /// @notice Borrow USD up to LTV limit. USD amounts are 18-decimal.
    function borrowUsd(uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidAmount();

        User storage u = users[msg.sender];
        if (u.stakedEth == 0) revert NoCollateralProvided();

        // maxBorrow = collateralValueUsd * ltvPct / 100
        uint256 maxBorrow = maxBorrowAllowed(msg.sender);

        if (u.borrowedUsd + amount > maxBorrow) {
            uint256 available = maxBorrow - u.borrowedUsd;
            revert BorrowLimitExceeded(amount, available);
        }

        // update state BEFORE external interactions
        u.borrowedUsd += amount;

        // transfer USD to borrower. If pool lacks tokens and token supports mint, mint the remainder.
        _ensureFundsAndTransfer(msg.sender, amount);

        emit USDBorrowed(msg.sender, amount);
    }

    /// @notice Repay borrowed USD. Overpayment not allowed.
    function repayUsd(uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidAmount();
        User storage u = users[msg.sender];
        if (u.borrowedUsd == 0) revert NoCollateralProvided();

        if (amount > u.borrowedUsd)
            revert OverPaymentNotSupported(amount, u.borrowedUsd);

        // transfer USD from payer to contract
        bool ok = usdToken.transferFrom(msg.sender, address(this), amount);
        if (!ok) revert TransferFailed();

        // update state
        u.borrowedUsd -= amount;

        emit USDRepaid(msg.sender, amount);
    }

    /// @notice Withdraw collateral (partial or full) if health remains >= 1 after withdrawal
    function withdrawCollateralEth(uint256 ethAmount) external nonReentrant {
        if (ethAmount == 0) revert InvalidAmount();

        User storage u = users[msg.sender];
        if (u.stakedEth < ethAmount)
            revert NotEnoughCollateral(u.stakedEth, ethAmount);

        // compute post-withdraw collateral value in USD
        uint256 newCollateralEth = u.stakedEth - ethAmount;
        uint256 ethPrice = priceOracle.getLatestPrice();
        uint256 newCollateralUsd = (newCollateralEth * ethPrice) / WAD;

        // compute required collateral per current borrowedUsd
        if (u.borrowedUsd > 0) {
            // requiredCollateralUsd = borrowedUsd * 100 / ltvPct
            uint256 requiredCollateralUsd = (u.borrowedUsd * PCT_DENOMINATOR) /
                ltvPct;
            if (newCollateralUsd < requiredCollateralUsd) {
                revert BorrowLimitExceeded(0, requiredCollateralUsd); // reuse error to indicate not allowed
            }
        }

        // update state then transfer ETH
        u.stakedEth = newCollateralEth;

        (bool sent, ) = payable(msg.sender).call{value: ethAmount}("");
        if (!sent) revert TransferFailed();

        emit ETHCollateralWithdrawn(msg.sender, ethAmount);
    }

    /* ============ Liquidation ============ */

    /// @notice Liquidate an undercollateralized position by repaying part or all of the borrow.
    /// liquidator provides USD (transferFrom) to repay `repayAmount`. They receive ETH collateral plus bonus.
    function liquidate(
        address borrower,
        uint256 repayAmount
    ) external nonReentrant {
        if (repayAmount == 0) revert InvalidAmount();
        if (borrower == address(0)) revert InvalidAddress(borrower);

        User storage u = users[borrower];
        if (u.borrowedUsd == 0) revert NoCollateralProvided();

        uint256 ethPrice = priceOracle.getLatestPrice();
        uint256 collateralUsd = collateralValueUsd(borrower);

        // compute health factor numerator = collateralUsd * liquidationThresholdPct
        // healthFactor = (collateralUsd * liquidationThresholdPct) / (borrowedUsd * 100)
        uint256 hfNumerator = collateralUsd * liquidationThresholdPct;
        uint256 hfDenominator = u.borrowedUsd * PCT_DENOMINATOR;

        // if healthFactor >= 1 => not liquidatable
        if (hfNumerator >= hfDenominator)
            revert NotLiquidatable((hfNumerator * WAD) / hfDenominator);

        // cap repayAmount to borrower's outstanding debt
        uint256 actualRepay = repayAmount > u.borrowedUsd
            ? u.borrowedUsd
            : repayAmount;

        // transfer USD from liquidator to contract
        bool ok = usdToken.transferFrom(msg.sender, address(this), actualRepay);
        if (!ok) revert TransferFailed();

        // compute ETH equivalent of repayAmount: ethAmount = repayUsd * WAD / ethPrice
        uint256 ethEquivalent = (actualRepay * WAD) / ethPrice;

        // apply liquidation bonus
        uint256 bonusNumer = BPS_DENOMINATOR + liquidationBonusBps; // e.g., 10000 + 500 = 10500
        uint256 seizedEth = (ethEquivalent * bonusNumer) / BPS_DENOMINATOR;

        // cap seizedEth to borrower's collateral
        if (seizedEth > u.stakedEth) {
            seizedEth = u.stakedEth;
        }

        // reduce borrower state
        u.borrowedUsd -= actualRepay;
        u.stakedEth -= seizedEth;

        // transfer seized ETH to liquidator
        (bool sent, ) = payable(msg.sender).call{value: seizedEth}("");
        if (!sent) revert TransferFailed();

        emit Liquidation(msg.sender, borrower, actualRepay, seizedEth);
    }

    /* ============ Views ============ */

    /// @notice Returns collateral value in USD (18 decimals)
    function collateralValueUsd(address user) public view returns (uint256) {
        return (users[user].stakedEth * priceOracle.getLatestPrice()) / WAD;
    }

    /// @notice Returns max borrow allowed (USD 18 decimals)
    function maxBorrowAllowed(address user) public view returns (uint256) {
        uint256 collateralUsd = collateralValueUsd(user);
        return (collateralUsd * ltvPct) / PCT_DENOMINATOR;
    }

    /// @notice Returns available to borrow right now
    function availableToBorrow(address user) external view returns (uint256) {
        uint256 maxBorrow = maxBorrowAllowed(user);
        if (users[user].borrowedUsd >= maxBorrow) return 0;
        return maxBorrow - users[user].borrowedUsd;
    }

    /// @notice Returns health factor scaled by WAD (>=WAD => healthy)
    function healthFactorWad(address user) public view returns (uint256) {
        User storage u = users[user];
        if (u.borrowedUsd == 0) return type(uint256).max;
        uint256 collateralUsd = collateralValueUsd(user);
        // HF = (collateralUsd * liquidationThresholdPct) / (borrowedUsd * 100)
        return
            (collateralUsd * liquidationThresholdPct * WAD) /
            (u.borrowedUsd * PCT_DENOMINATOR);
    }

    /* ============ Internal helpers ============ */

    // transfer amount of usdToken to recipient; if contract lacks funds and token has mint, mint the shortfall
    function _ensureFundsAndTransfer(address to, uint256 amount) internal {
        uint256 bal = usdToken.balanceOf(address(this));
        if (bal >= amount) {
            bool ok = usdToken.transfer(to, amount);
            if (!ok) revert TransferFailed();
            return;
        }

        // If token supports mint, mint the shortfall; else revert
        uint256 shortfall = amount - bal;
        if (bal > 0) {
            bool ok1 = usdToken.transfer(to, bal);
            if (!ok1) revert TransferFailed();
        }

        // try to mint shortfall (works in tests with MockUsdt implementing mint)
        try IMintableERC20(address(usdToken)).mint(to, shortfall) returns (
            bool minted
        ) {
            if (!minted) revert UnsupportedToken();
        } catch {
            revert InsufficientPoolFunds(amount, bal);
        }
    }

    /* ============ Receive / Fallback ============ */
    receive() external payable {}
    fallback() external payable {}
}
