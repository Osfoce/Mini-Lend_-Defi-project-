//SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {FixedPointMathLib} from "@solmate/src/utils/FixedPointMathLib.sol";

contract MiniLend is ReentrancyGuard, Ownable(msg.sender) {
    using FixedPointMathLib for uint256;

    /* ============ Errors ============ */
    error TransferFailed(address token, address sender, uint256 amount);
    error TokenTransferFailed(address token, address to, uint256 amount);
    error BorrowLimitExceeded(uint256 amount, uint256 availableToBorrow);
    error OverPaymentNotSupported(uint256 amountPaid, uint256 expectedAmount);
    error NotEnoughCollateral(uint256 collateralBalance, uint256 userInput);
    error InvalidAsset(address asset);
    error BorrowedAmountNotFullyRepaid(uint256 balance);
    error TokenAlreadyApproved(address token);
    error TokenNotApproved(address token);
    error InvalidPriceData(int256 price);
    error InsufficientPoolBalance(uint256 poolBalance, uint256 requestedAmount);
    error InvalidAddress(address addr);
    error FeedDataNotFinalized();
    error StalePriceData(uint256 data);
    error NoCollateralProvided();
    error InsufficientCollateral();
    error InsufficientEthBalance();
    error InvalidDecimals();
    error BadBonus(uint256 bonus);
    error InvalidCloseFactor();
    error InvalidAmount();
    error PositionHealthy();
    error NoActivePosition();
    error Badltv(uint256 ltv);

    /* ============ Events ============ */
    event ltvUpdated(uint256 newltv);
    event BonusUpdated(uint256 newBonus);
    event TokenRevoked(address indexed token);
    event NewTokenApproved(address indexed token);
    event PriceFeedUpdated(address indexed token, address indexed feed);
    event MockUsdtAddressUpdated(address newAddress);
    event EthStaked(address indexed user, uint256 ethAmount);
    event USDRepaid(address indexed user, uint256 usdAmount);
    event USDBorrowed(address indexed user, uint256 usdAmount);
    event ETHCollateralWithdrawn(address indexed user, uint256 amount);
    event Liquidation(
        address indexed liquidator,
        address indexed borrower,
        uint256 repayAmount,
        uint256 seizedCollateral
    );

    /* ============ Structs ============ */
    struct User {
        address stakedAsset;
        uint256 stakedAmount;
        address debtAsset;
        uint256 debtAmount;
    }

    /* ============ State ============ */
    mapping(address => User) public users;
    mapping(address => address) public priceFeeds;

    // approved tokens that the pool can lend
    mapping(address => bool) public approvedTokens;
    mapping(address => uint256) public tokenIndex; // index in approvedTokenList

    address[] public approvedTokenList;
    uint256 private ltv = 5000; // 50% (5000 bps)
    uint256 private closeFactor = 5000; // 50% (5000 bps)
    uint256 private liquidationBonus = 500; // 5% (500 bps)
    uint256 private constant WAD = 1e18;
    uint256 private constant PCT_DENOMINATOR = 10000; // for percentage calculations
    uint256 private constant LIQUIDATION_THRESHOLD = 7500;
    address public constant ETH_ADDRESS =
        0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE; // ETH address representation

    // =========== Modifiers ============
    modifier onlyApprovedToken(address token) {
        _onlyApprovedToken(token);
        _;
    }

    modifier nonZeroAddress(address addr) {
        _invalidAddrress(addr);
        _;
    }

    modifier nonZeroAmount(uint256 amount) {
        _invalidValue(amount);
        _;
    }

    modifier onlyActive(address borrower) {
        _onlyActive(borrower);
        _;
    }

    /* ============ Receive / Fallback ============ */
    receive() external payable {}

    fallback() external payable {}

    // =========== Admin Functions ============
    function setFeed(
        address token,
        address feed
    ) external onlyOwner nonZeroAddress(token) nonZeroAddress(feed) {
        priceFeeds[token] = feed;
        emit PriceFeedUpdated(token, feed);
    }

    function setltv(uint256 _ltv) external onlyOwner nonZeroAmount(_ltv) {
        if (_ltv == 0 || _ltv > PCT_DENOMINATOR || _ltv > LIQUIDATION_THRESHOLD)
            revert Badltv(_ltv);
        ltv = _ltv;
        emit ltvUpdated(_ltv);
    }

    function setLiquidationBonus(
        uint256 _bonus
    ) external onlyOwner nonZeroAmount(_bonus) {
        if (_bonus > PCT_DENOMINATOR) revert BadBonus(_bonus);
        liquidationBonus = _bonus;
        emit BonusUpdated(_bonus);
    }

    function approveToken(
        address token
    ) external onlyOwner nonZeroAddress(token) {
        if (approvedTokens[token]) revert TokenAlreadyApproved(token);

        approvedTokens[token] = true;
        tokenIndex[token] = approvedTokenList.length;
        approvedTokenList.push(token);

        emit NewTokenApproved(token);
    }

    function revokeTokenApproval(
        address token
    ) external onlyOwner nonZeroAddress(token) {
        if (!approvedTokens[token]) revert TokenNotApproved(token);

        approvedTokens[token] = false;

        // Remove from approvedTokenList
        uint256 index = tokenIndex[token];
        uint256 lastIndex = approvedTokenList.length - 1;
        address lastToken = approvedTokenList[lastIndex];

        if (index != lastIndex) {
            // Move last element to removed position
            approvedTokenList[index] = lastToken;
            tokenIndex[lastToken] = index;
        }

        approvedTokenList.pop();
        delete tokenIndex[token];
        emit TokenRevoked(token);
    }

    // ========== Public view Functions ============

    // @notice Chainlink returns the USD value of 1 unit of the token
    //Example; Chainlink tells me 1 ETH = $2,500 normalised to 18 decimals
    // Then I calculate: 5 ETH × $2,500 = $12,500 worth
    function getLatestPrice(
        address token
    ) public view nonZeroAddress(token) returns (uint256) {
        address feedAddress = priceFeeds[token];
        if (feedAddress == address(0)) revert InvalidAddress(feedAddress);

        AggregatorV3Interface feed = AggregatorV3Interface(feedAddress);
        (
            uint80 roundId,
            int256 price,
            ,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = feed.latestRoundData();

        // validity checks
        if (price <= 0) revert InvalidPriceData(price);
        if (answeredInRound < roundId) revert FeedDataNotFinalized();

        if (
            updatedAt == 0 || (block.timestamp - uint256(updatedAt)) >= 1 hours
        ) {
            revert StalePriceData(uint256(updatedAt));
        }

        uint8 decimals = feed.decimals();
        if (decimals > 18) revert InvalidDecimals();
        // casting to uint256 is safe because price is validated to be > 0 above
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint256(price) * 10 ** (18 - decimals);
    }

    function getUsdValue(
        address token,
        uint256 amount
    ) public view returns (uint256 usdValue) {
        // Gets the price of 1 unit of token in USD (18 decimals)
        uint256 price = uint256(getLatestPrice(token)); // 18 decimals
        if (price == 0) return 0;

        // get token decimals
        uint8 decimals = token == ETH_ADDRESS
            ? 18
            : IERC20Metadata(token).decimals();

        if (decimals > 18) revert InvalidDecimals();

        // Normalize token amount to 18 decimals
        uint256 normalized = amount * (10 ** (18 - decimals));

        // Calculate USD equivalent with 18 decimals
        // return usdValue = (normalized * price) / 1e18;
        return normalized.mulDivDown(price, WAD);
    }

    function getContractsTokenBalance(
        address token
    ) external view nonZeroAddress(token) returns (uint256) {
        IERC20 erc = IERC20(token);
        return erc.balanceOf(address(this));
    }

    /// @notice Returns user info as a memory copy for frontend/UI consumption.
    /// @dev External callers cannot get storage references, so return memory version.
    function getUser(
        address user
    )
        external
        view
        returns (
            address stakedAsset,
            uint256 stakedAmount,
            address debtAsset,
            uint256 debtAmount
        )
    {
        User storage u = users[user];
        return (u.stakedAsset, u.stakedAmount, u.debtAsset, u.debtAmount);
    }

    function ethBalance() public view returns (uint256) {
        return address(this).balance;
    }

    function isTokenApproved(
        address token
    ) external view nonZeroAddress(token) returns (bool) {
        return approvedTokens[token];
    }

    function getApprovedTokensCount() external view returns (uint256) {
        return approvedTokenList.length;
    }

    // ========== Core Functions ============

    /**
     * @notice Stakes ETH as collateral in the protocol.
     *
     * @dev The caller sends ETH along with this transaction, which is recorded
     *      as collateral backing the caller’s borrowing position.
     *
     * @dev Computation flow:
     * - `msg.value` is treated as the staked collateral amount.
     * - The ETH/USD price is fetched via the configured price feed.
     * - The USD value of the collateral is tracked implicitly through pricing logic.
     *
     * Requirements:
     * - `msg.value` must be greater than zero.
     * - Caller must not be in a clearPositioned state.
     *
     * Effects:
     * - Increases the caller’s `stakedAmount`.
     * - Sets the caller’s `stakedAsset` to ETH if not already set.
     *
     * Emits a {Stake} event on success.
     */

    function stakeEth() public payable {
        if (msg.value == 0) revert NoCollateralProvided();
        User storage user = _user(msg.sender);
        user.stakedAmount += msg.value;
        user.stakedAsset = ETH_ADDRESS;
        emit EthStaked(msg.sender, msg.value);
    }

    /**
     * @notice Borrows an approved asset against the caller’s collateral.
     *
     * @dev The borrow amount is limited by the loan-to-value (LTV) ratio of the
     *      caller’s staked collateral.
     *
     * @param token The address of the asset to borrow.
     * @param amount The amount of the asset to borrow (in token units, 18-decimal assumed).
     *
     * @dev Computation flow:
     * - `collateralUsdValue`: USD value of the caller’s staked collateral.
     * - `borrowedUsdValue`: USD value of existing debt (if any).
     * - `assetPrice`: USD price of the asset being borrowed.
     * - `borrowUsdValue`: USD value of the requested borrow amount.
     * - LTV check ensures:
     *   `borrowedUsdValue + borrowUsdValue <= collateralUsdValue * LTV / PCT_DENOMINATOR`
     *
     * Requirements:
     * - Caller must have an active collateral position.
     * - Asset must be approved for borrowing.
     * - Borrow amount must be greater than zero.
     * - Resulting position must not exceed the maximum LTV.
     * - Contract must have sufficient liquidity of the borrowed asset.
     *
     * Effects:
     * - Increases the caller’s `debtAmount`.
     * - Sets `debtAsset` if this is the first borrow.
     * - Transfers borrowed assets to the caller.
     *
     * Emits a {Borrow} event on success.
     */
    function borrowAsset(
        address token,
        uint256 amount
    )
        external
        nonReentrant
        nonZeroAddress(token)
        nonZeroAmount(amount)
        onlyApprovedToken(token)
    {
        User storage user = _user(msg.sender);

        if (!_hasCollateral(msg.sender)) revert NoCollateralProvided();

        // calculate max borrow
        // uint256 availableToBorrow =
        uint256 available = _borrowableAmount(msg.sender, token);
        if (amount > available) revert BorrowLimitExceeded(amount, available);

        // update state
        user.debtAmount += amount;
        user.debtAsset = token;

        // Transfer logic
        _poolTransfer(token, msg.sender, amount);

        emit USDBorrowed(msg.sender, amount);
    }

    /**
     * @notice Repays an outstanding borrowed asset.
     *
     * @dev The caller repays part or all of their existing debt for a given asset.
     *
     * @param token The address of the borrowed asset being repaid.
     * @param repayAmount The amount of the asset to repay (in token units, 18-decimal assumed).
     *
     * @dev Computation flow:
     * - `actualRepay`: The lesser of `amount` and the caller’s outstanding `debtAmount`.
     * - Debt accounting is updated using `actualRepay`.
     *
     * Requirements:
     * - Caller must have an active borrowing position.
     * - Asset must match the caller’s borrowed asset.
     * - Repay amount must be greater than zero.
     * - Caller must approve the repay asset to this contract.
     *
     * Effects:
     * - Decreases the caller’s `debtAmount`.
     * - Clears `debtAsset` if the debt is fully repaid.
     * - Transfers repaid tokens from the caller to the contract.
     *
     * Emits a {Repay} event on success.
     */
    function repayAsset(
        address token,
        uint256 repayAmount
    )
        public
        nonZeroAddress(token)
        nonZeroAmount(repayAmount)
        onlyApprovedToken(token)
    {
        User storage user = _user(msg.sender);
        if (!_activePosition(msg.sender)) revert NoActivePosition();
        if (!_repayWithdebtAsset(msg.sender, token)) revert InvalidAsset(token);

        /*//////////////////////////////////////////////////////////////
                    1. PRICE-AWARE REPAY
        //////////////////////////////////////////////////////////////*/

        // USD value of the repayment at current price
        uint256 repayUsdValue = getUsdValue(token, repayAmount);

        // USD value of the outstanding debt
        uint256 debtUsdValue = getUsdValue(user.debtAsset, user.debtAmount);

        if (repayUsdValue > debtUsdValue) {
            revert OverPaymentNotSupported(repayAmount, user.debtAmount);
        }

        /*//////////////////////////////////////////////////////////////
                        2. TOKEN TRANSFER
        //////////////////////////////////////////////////////////////*/

        if (
            !IERC20(user.debtAsset).transferFrom(
                msg.sender,
                address(this),
                repayAmount
            )
        ) revert TransferFailed(user.debtAsset, msg.sender, repayAmount);

        /*//////////////////////////////////////////////////////////////
                        3. UPDATE DEBT
        //////////////////////////////////////////////////////////////*/

        uint256 debtPrice = getLatestPrice(user.debtAsset);

        // Convert remaining USD debt back into token units
        uint256 remainingUsdDebt = debtUsdValue - repayUsdValue;

        uint256 newDebtAmount = remainingUsdDebt.mulDivDown(WAD, debtPrice);

        user.debtAmount = newDebtAmount;

        if (user.debtAmount == 0) {
            user.debtAsset = address(0);
        }

        emit USDRepaid(msg.sender, repayUsdValue);
    }

    /**
     * @notice Withdraws staked ETH collateral from the protocol.
     *
     * @dev Allows a user to withdraw a portion or all of their ETH collateral
     *      provided that all outstanding debt has been fully repaid.
     *
     * @param amount The amount of ETH (in wei) to withdraw from the caller’s
     *        staked collateral balance.
     *
     * @dev Computation and checks:
     * - Verifies that the caller has no outstanding debt (`debtAmount == 0`).
     * - Ensures the requested withdrawal amount does not exceed the caller’s
     *   available staked collateral.
     * - Confirms the protocol contract holds sufficient ETH liquidity.
     *
     * Requirements:
     * - Caller must have an active collateral position.
     * - All borrowed assets must be fully repaid before withdrawal.
     * - `amount` must be greater than zero.
     * - `amount` must be less than or equal to the caller’s staked collateral.
     * - Contract must have sufficient ETH balance to fulfill the withdrawal.
     *
     * Effects:
     * - Decreases the caller’s `stakedAmount` by `amount`.
     * - Resets the caller’s position if all collateral is withdrawn.
     * - Transfers `amount` of ETH to the caller.
     *
     * Emits an {ETHCollateralWithdrawn} event on success.
     */
    function withdrawCollateralEth(
        uint256 amount
    ) public nonReentrant nonZeroAmount(amount) {
        User storage user = _user(msg.sender);
        if (user.debtAmount != 0)
            revert BorrowedAmountNotFullyRepaid(user.debtAmount);
        if (amount > user.stakedAmount)
            revert NotEnoughCollateral(user.stakedAmount, amount);

        // Transfer ETH
        if (address(this).balance < amount)
            revert InsufficientPoolBalance(address(this).balance, amount);

        _sendEth(msg.sender, amount);

        // update state
        user.stakedAmount -= amount;

        if (user.stakedAmount == 0) {
            _clearPosition(msg.sender);
        }

        emit ETHCollateralWithdrawn(msg.sender, amount);
    }

    /**
     * @notice Liquidates an undercollateralized borrowing position.
     *
     * @dev The liquidator repays part of the borrower's outstanding debt and
     *      receives collateral at a discount (liquidation bonus).
     *
     * @param borrower The address of the borrower whose position is being liquidated.
     * @param repayAmount The amount of debt token the liquidator is willing to repay
     *        on behalf of the borrower (in debt token units, 18-decimal assumed).
     *
     * @dev Computation flow:
     * - `collateralUsdValue`: USD value of the borrower’s collateral.
     * - `borrowedUsdValue`: USD value of the borrower’s outstanding debt.
     * - `thresholdUsd`: Maximum allowed borrowed USD before liquidation is triggered.
     * - `maxRepayByCloseFactor`: Max repay allowed by protocol close factor.
     * - `maxRepayUsdByCollateral`: Max repay supported by available collateral value.
     * - `debtPrice`: USD price of the borrowed asset.
     * - `maxRepayByCollateral`: Max repay amount derived from collateral constraints.
     * - `actualRepay`: Final repay amount after applying all caps.
     * - `repayUsdValue`: USD value of `actualRepay`.
     * - `seizableUsd`: USD value of collateral to seize (includes liquidation bonus).
     * - `collateralPrice`: USD price per unit of collateral asset.
     * - `seizableAmount`: Amount of collateral tokens transferred to the liquidator.
     *
     * Requirements:
     * - Borrower must have an active position.
     * - Borrowed USD value must exceed the liquidation threshold.
     * - Repayment is capped by both close factor and collateral availability.
     * - Liquidator must approve the debt asset to this contract.
     * - Contract must hold sufficient collateral (ETH or ERC20) to pay the liquidator.
     *
     * Emits a {Liquidation} event on success.
     */

    function liquidate(
        address borrower,
        uint256 repayAmount
    )
        external
        nonReentrant
        nonZeroAddress(borrower)
        nonZeroAmount(repayAmount)
    {
        User storage user = _user(borrower);
        if (!_activePosition(borrower)) revert NoActivePosition();

        /*//////////////////////////////////////////////////////////////
                        1. USD VALUATIONS
        //////////////////////////////////////////////////////////////*/

        uint256 collateralUsdValue = getUsdValue(
            user.stakedAsset,
            user.stakedAmount
        );

        uint256 borrowedUsdValue = getUsdValue(user.debtAsset, user.debtAmount);

        uint256 thresholdUsd = collateralUsdValue.mulDivDown(
            LIQUIDATION_THRESHOLD,
            PCT_DENOMINATOR
        );

        if (borrowedUsdValue <= thresholdUsd) revert PositionHealthy();

        /*//////////////////////////////////////////////////////////////
                        2. REPAY CAPS
        //////////////////////////////////////////////////////////////*/

        if (closeFactor == 0 || closeFactor > PCT_DENOMINATOR)
            revert InvalidCloseFactor();

        // (A) cap by close factor
        uint256 maxRepayByCloseFactor = user.debtAmount.mulDivDown(
            closeFactor,
            PCT_DENOMINATOR
        );

        // (B) cap by available collateral value
        uint256 maxRepayUsdByCollateral = collateralUsdValue.mulDivDown(
            PCT_DENOMINATOR,
            PCT_DENOMINATOR + liquidationBonus
        );

        uint256 debtPrice = getLatestPrice(user.debtAsset);

        uint256 maxRepayByCollateral = maxRepayUsdByCollateral.mulDivDown(
            WAD,
            debtPrice
        );

        // final repay cap
        uint256 actualRepay = repayAmount;
        if (actualRepay > maxRepayByCloseFactor) {
            actualRepay = maxRepayByCloseFactor;
        }
        if (actualRepay > maxRepayByCollateral) {
            actualRepay = maxRepayByCollateral;
        }

        if (actualRepay == 0) revert InsufficientCollateral();

        /*//////////////////////////////////////////////////////////////
                    3. COLLATERAL SEIZURE
        //////////////////////////////////////////////////////////////*/

        uint256 repayUsdValue = getUsdValue(user.debtAsset, actualRepay);
        //The USD value of collateral the liquidator earns for repaying the debt.
        uint256 seizableUsd = repayUsdValue.mulDivDown(
            PCT_DENOMINATOR + liquidationBonus,
            PCT_DENOMINATOR
        );
        // How much 1 unit of collateral is worth in USD
        uint256 collateralPrice = getLatestPrice(user.stakedAsset);
        // How many tokens the liquidator actually receives
        uint256 seizableAmount = seizableUsd.mulDivDown(WAD, collateralPrice);

        if (seizableAmount > user.stakedAmount) {
            seizableAmount = user.stakedAmount;
        }

        /*//////////////////////////////////////////////////////////////
                4. PRE-CHECK ETH BALANCE (CRITICAL)
        //////////////////////////////////////////////////////////////*/

        if (user.stakedAsset == ETH_ADDRESS) {
            if (ethBalance() < seizableAmount) {
                revert InsufficientEthBalance();
            }
        }

        /*//////////////////////////////////////////////////////////////
                5. EFFECTS + INTERACTIONS
        //////////////////////////////////////////////////////////////*/

        if (
            !IERC20(user.debtAsset).transferFrom(
                msg.sender,
                address(this),
                actualRepay
            )
        ) revert TransferFailed(user.debtAsset, msg.sender, actualRepay);

        user.debtAmount -= actualRepay;

        if (user.stakedAsset == ETH_ADDRESS) {
            _sendEth(msg.sender, seizableAmount);
        }

        user.stakedAmount -= seizableAmount;

        if (user.stakedAmount == 0) {
            _clearPosition(borrower);
        }

        emit Liquidation(msg.sender, borrower, actualRepay, seizableAmount);
    }

    // ============ Internal helper Functions ============

    function _user(address user) internal view returns (User storage) {
        return users[user];
    }

    function _hasCollateral(address user) internal view returns (bool) {
        return users[user].stakedAmount > 0;
    }

    function _activePosition(address user) internal view returns (bool) {
        return users[user].debtAmount > 0;
    }

    function _onlyApprovedToken(address token) internal view {
        if (!approvedTokens[token]) revert TokenNotApproved(token);
    }

    function _invalidAddrress(address addr) internal pure {
        if (addr == address(0)) revert InvalidAddress(addr);
    }

    function _invalidValue(uint256 amount) internal pure {
        if (amount == 0) revert InvalidAmount();
    }

    function _onlyActive(address borrower) internal view {
        if (!_activePosition(borrower)) revert NoActivePosition();
    }

    function _repayWithdebtAsset(
        address user,
        address token
    ) internal view returns (bool) {
        return (users[user].debtAsset == token);
    }

    function _sendEth(address to, uint256 amount) internal {
        (bool sent, ) = payable(to).call{value: amount}("");
        if (!sent) revert TransferFailed(ETH_ADDRESS, to, amount);
    }

    function _clearPosition(address user) internal {
        User storage u = _user(user);
        u.debtAsset = address(0);
        u.debtAmount = 0;
        u.stakedAsset = address(0);
        u.stakedAmount = 0;
    }

    function _getTokenDecimals(address token) internal view returns (uint8) {
        if (token == ETH_ADDRESS) {
            return 18;
        }
        try IERC20Metadata(token).decimals() returns (uint8 decimals) {
            return decimals;
        } catch {
            revert InvalidDecimals();
        }
    }

    function _poolTransfer(address token, address to, uint256 amount) internal {
        IERC20 erc = IERC20(token);
        uint256 balance = erc.balanceOf(address(this));

        if (balance < amount) {
            revert InsufficientPoolBalance(balance, amount);
        }

        if (!erc.transfer(to, amount))
            revert TokenTransferFailed(token, to, amount);
    }

    function _borrowableAmount(
        address user,
        address token
    ) internal view returns (uint256) {
        User storage u = _user(user);
        //  User must have collateral
        if (!_hasCollateral(user)) return 0;

        //  Ensure token has a valid oracle feed
        if (priceFeeds[token] == address(0)) {
            revert InvalidAsset(token);
        }

        //  get USD value of staked asset
        uint256 assetUsdValue = getUsdValue(u.stakedAsset, u.stakedAmount);
        //  Borrowing power = collateralUsd × ltv
        uint256 borrowingPower = assetUsdValue.mulDivDown(ltv, PCT_DENOMINATOR);

        //  USD value of what the user already borrowed
        uint256 borrowedUsd = u.debtAmount == 0
            ? 0
            : getUsdValue(u.debtAsset, u.debtAmount);

        //  Prevent underflow: user borrowed more than allowed
        if (borrowedUsd >= borrowingPower) {
            return 0; // or revert BorrowLimitExceeded();
        }

        // available to borrow in USD
        uint256 availableToBorrowInUsd = borrowingPower - borrowedUsd;
        if (availableToBorrowInUsd == 0) {
            return 0;
        }

        // Get USD price of the token they want to borrow
        uint256 tokenPrice = getLatestPrice(token);
        //  Convert USD borrowing power → Token units
        // USD (18 decimals) / price (18 decimals) → token amount (18 decimals)
        return availableToBorrowInUsd.mulDivDown(WAD, tokenPrice);
    }
}
