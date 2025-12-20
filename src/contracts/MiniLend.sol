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

    function getContractEthBalance() external view returns (uint256) {
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

    /// @notice Stake ETH as collateral
    function stakeEth() public payable {
        if (msg.value == 0) revert NoCollateralProvided();
        User storage user = _user(msg.sender);
        user.stakedAmount += msg.value;
        user.stakedAsset = ETH_ADDRESS;
        emit EthStaked(msg.sender, msg.value);
    }

    /// @notice Borrow a supported token from the pool. `amount` is token units (assumed 18-dec).
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

    /// @notice Repay borrowed token. amount is token units (18-dec)
    function repayAsset(
        address token,
        uint256 amount
    )
        public
        nonZeroAddress(token)
        nonZeroAmount(amount)
        onlyApprovedToken(token)
    {
        User storage user = _user(msg.sender);
        if (!_activePosition(msg.sender)) revert NoActivePosition();
        if (!_repayWithdebtAsset(msg.sender, token)) revert InvalidAsset(token);

        if (amount > user.debtAmount)
            revert OverPaymentNotSupported(amount, user.debtAmount);

        // Transfer logic
        if (
            !IERC20(user.debtAsset).transferFrom(
                msg.sender,
                address(this),
                amount
            )
        ) revert TransferFailed(user.debtAsset, msg.sender, amount);

        // update state
        user.debtAmount -= amount;

        if (user.debtAmount == 0) {
            user.debtAsset = address(0);
        }

        emit USDRepaid(msg.sender, amount);
    }

    // collateral can be withdrawn only when borrowed usdt is fully repaid
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

        (bool success, ) = address(msg.sender).call{value: amount}("");
        if (!success) revert TransferFailed(address(0), msg.sender, amount);

        // update state
        user.stakedAmount -= amount;

        if (user.stakedAmount == 0) {
            _default(msg.sender);
        }

        emit ETHCollateralWithdrawn(msg.sender, amount);
    }

    /// @notice Liquidate an undercollateralized position.
    /// @param borrower The borrower to liquidate.
    /// @param repayAmount The amount (in borrowed token units, 18-dec assumed) the liquidator will repay on behalf of the borrower.
    /// Requirements:
    /// - borrower's position must exist and be below the liquidation threshold
    /// - repayAmount is capped by closeFactor_BPS of outstanding debtAmount
    /// - liquidator must `approve` repay token to this contract
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

        // === 1) Compute current USD values of collateral and debt ===
        // collateralUsdValue and borrowedUsd are in 18-decimal USD units
        uint256 collateralUsdValue = getUsdValue(
            user.stakedAsset,
            user.stakedAmount
        );
        uint256 borrowedUsd = getUsdValue(user.debtAsset, user.debtAmount);

        // === 2) Check if position is liquidatable ===
        // Position is liquidatable if borrowedUsd > collateralUsdValue * LIQUIDATION_THRESHOLD_BPS / BPS_DENOMINATOR
        uint256 thresholdUsd = collateralUsdValue.mulDivDown(
            LIQUIDATION_THRESHOLD,
            PCT_DENOMINATOR
        );

        if (borrowedUsd <= thresholdUsd) revert PositionHealthy(); // not eligible for liquidation

        // === 3) Determine the maximum repay allowed by close factor ===
        // closeFactor caps how much of the borrow can be repaid in one liquidation (e.g., 50%).
        if (closeFactor == 0 || closeFactor > PCT_DENOMINATOR)
            revert InvalidCloseFactor();
        // cap repayAmount to borrower's outstanding debtAmount * closeFactor_BPS / BPS_DENOMINATOR
        uint256 maxRepayAllowed = user.debtAmount.mulDivDown(
            closeFactor,
            PCT_DENOMINATOR
        );

        uint256 actualRepay = repayAmount > maxRepayAllowed
            ? maxRepayAllowed
            : repayAmount;

        // compute USD value of the actualRepay
        uint256 repayUsdValue = getUsdValue(user.debtAsset, actualRepay);

        // === 4) Compute how much collateral (in USD) is seizable, then convert to collateral token units ===
        // seizableUsd = repayUsdValue * (1 + liquidationBonus)
        uint256 seizableUsd = repayUsdValue.mulDivDown(
            PCT_DENOMINATOR + liquidationBonus,
            PCT_DENOMINATOR
        );

        // Get price of collateral token (USD per token, 18-dec). If collateral is ETH, token address should be ETH_ADDRESS or handled inside getLatestPrice.
        uint256 collateralPrice = getLatestPrice(user.stakedAsset); // 18-dec USD per 1 unit of collateral token

        // seizableAmount in collateral token units = seizableUsd * WAD / collateralPrice
        // (WAD scaling because both seizableUsd and collateralPrice are 18-dec)
        uint256 seizableAmount = seizableUsd.mulDivDown(WAD, collateralPrice);

        // Cap seized collateral to what borrower actually has
        if (seizableAmount > user.stakedAmount) {
            seizableAmount = user.stakedAmount;
        }

        // === 5) Pull repay tokens from liquidator into pool/contract ===
        // liquidator must approve this contract to transfer actualRepay of debtAsset
        if (
            !IERC20(user.debtAsset).transferFrom(
                msg.sender,
                address(this),
                actualRepay
            )
        ) revert TransferFailed(user.debtAsset, msg.sender, actualRepay);

        // === 6) Update borrower state (checks-effects-interactions) ===
        // Reduce borrowed asset amount and borrowedUsd (use repayUsdValue)
        if (actualRepay >= user.debtAmount) {
            // Repaying all (should not happen due to close factor but handle it)
            user.debtAmount = 0;
            // user.borrowedUsd = 0;
            user.debtAsset = address(0);
        }

        user.debtAmount -= actualRepay;

        // === 7) Send seized collateral to liquidator (handle ETH vs ERC20) ===
        if (user.stakedAsset == ETH_ADDRESS) {
            // payable(msg.sender).transfer(seizeAmount);
            // ETH collateral
            (bool sent, ) = payable(msg.sender).call{value: seizableAmount}("");
            if (!sent)
                revert TransferFailed(ETH_ADDRESS, msg.sender, seizableAmount);
        }

        // Reduce collateral
        user.stakedAmount -= seizableAmount;

        if (user.stakedAmount == 0) {
            _default(borrower);
        }

        // Eth is the collateral token at the moment, so no ERC20 collateral handling
        //  else {
        //     // ERC20 collateral token
        //     bool ok2 = IERC20(user.stakedAsset).transfer(
        //         msg.sender,
        //         seizableAmount
        //     );
        //     if (!ok2)
        //         revert TransferFailed(
        //             user.stakedAsset,
        //             msg.sender,
        //             seizableAmount
        //         );
        // }

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

    function _default(address user) internal {
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
