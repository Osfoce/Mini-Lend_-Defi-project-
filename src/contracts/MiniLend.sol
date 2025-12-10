//SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Address.sol";

contract MiniLend is ReentrancyGuard, Ownable(msg.sender) {
    using Address for address payable;

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
    error InvalidAmount();
    error NoActivePosition();
    error BadLtv(uint256 ltv);

    /* ============ Events ============ */
    event LtvUpdated(uint256 newLtv);
    event BonusUpdated(uint256 newBonus);
    event TokenRevoked(address indexed token);
    event NewTokenApproved(address indexed token);
    event PriceFeedUpdated(address indexed token, address indexed feed);
    event MockUsdtAddressUpdated(address newAddress);
    event EthStaked(address indexed user, uint256 ethAmount);
    event USDRepaid(address indexed user, uint256 usdAmount);
    event USDBorrowed(address indexed user, uint256 usdAmount);
    event ETHCollateralWithdrawn(address indexed user, uint256 amount);

    /* ============ Structs ============ */
    struct User {
        address stakedAsset;
        uint256 stakedAmount;
        address borrowedAsset;
        uint256 borrowedAssetAmount;
    }

    /* ============ State ============ */
    mapping(address => User) public users;
    mapping(address => address) public priceFeeds;

    // approved tokens that the pool can lend
    mapping(address => bool) public approvedTokens;
    mapping(address => uint256) public tokenIndex; // index in approvedTokenList
    address[] public approvedTokenList;
    address ethAddress = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE; // ETH address representation

    uint256 private LTV = 5000; // 50% (5000 bps)
    uint256 private LIQUIDATION_BONUS = 500; // 5% (500 bps)
    uint256 private constant WAD = 1e18;
    uint256 private constant PCT_DENOMINATOR = 10000; // for percentage calculations
    uint256 private constant LIQUIDATION_THRESHOLD = 7500;

    // =========== Modifiers ============
    modifier onlyApprovedToken(address token) {
        if (!approvedTokens[token]) revert TokenNotApproved(token);
        _;
    }

    modifier nonZeroAddress(address addr) {
        if (addr == address(0)) revert InvalidAddress(addr);
        _;
    }

    modifier nonZeroAmount(uint256 amount) {
        if (amount == 0) revert InvalidAmount();
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

    function setLtv(uint256 _ltv) external onlyOwner nonZeroAmount(_ltv) {
        if (_ltv == 0 || _ltv > PCT_DENOMINATOR || _ltv > LIQUIDATION_THRESHOLD)
            revert BadLtv(_ltv);
        LTV = _ltv;
        emit LtvUpdated(_ltv);
    }

    function setLiquidationBonus(
        uint256 _bonus
    ) external onlyOwner nonZeroAmount(_bonus) {
        if (_bonus > PCT_DENOMINATOR) revert BadBonus(_bonus);
        LIQUIDATION_BONUS = _bonus;
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

        AggregatorV3Interface priceFeed = AggregatorV3Interface(feedAddress);
        (
            uint80 roundId,
            int256 price,
            ,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = priceFeed.latestRoundData();

        // validity checks
        if (price <= 0) revert InvalidPriceData(price);
        if (answeredInRound < roundId) revert FeedDataNotFinalized();

        if (
            updatedAt == 0 || (block.timestamp - uint256(updatedAt)) >= 1 hours
        ) {
            revert StalePriceData(uint256(updatedAt));
        }

        uint256 decimals = priceFeed.decimals();
        if (decimals > 18) revert InvalidDecimals();
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
        uint8 tokenDecimals = _getTokenDecimals(token);

        // Normalize token amount to 18 decimals
        uint256 normalizedAmount = amount * (10 ** (18 - tokenDecimals));

        // Calculate USD equivalent with 18 decimals
        return usdValue = (normalizedAmount * price) / 1e18;
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
            address borrowedAsset,
            uint256 borrowedAssetAmount
        )
    {
        User storage u = users[user];
        return (
            u.stakedAsset,
            u.stakedAmount,
            u.borrowedAsset,
            u.borrowedAssetAmount
        );
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
        user.stakedAsset = ethAddress;
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
        _borrowableAmount(msg.sender, token);
        // if (availableToBorrow <= 0)
        //     revert BorrowLimitExceeded(amount, availableToBorrow);

        // update state
        user.borrowedAssetAmount += amount;
        user.borrowedAsset = token;

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
        if (!_repayWithBorrowedAsset(msg.sender, token))
            revert InvalidAsset(token);

        if (amount > user.borrowedAssetAmount)
            revert OverPaymentNotSupported(amount, user.borrowedAssetAmount);

        // Transfer logic
        IERC20(user.borrowedAsset).approve(address(this), amount);

        bool sucess = IERC20(user.borrowedAsset).transferFrom(
            msg.sender,
            address(this),
            amount
        );

        if (!sucess)
            revert TransferFailed(user.borrowedAsset, msg.sender, amount);

        // update state
        user.borrowedAssetAmount -= amount;

        emit USDRepaid(msg.sender, amount);
    }

    // collateral can be withdrawn only when borrowed usdt is fully repaid
    function withdrawCollateralEth(
        uint256 amount
    ) public nonReentrant nonZeroAmount(amount) {
        User storage user = _user(msg.sender);
        if (user.borrowedAssetAmount != 0)
            revert BorrowedAmountNotFullyRepaid(user.borrowedAssetAmount);
        if (amount > user.stakedAmount)
            revert NotEnoughCollateral(user.stakedAmount, amount);

        // Transfer ETH
        (bool success, ) = address(msg.sender).call{value: amount}("");
        if (!success) revert TransferFailed(address(0), msg.sender, amount);

        // update state
        user.stakedAmount -= amount;

        if (user.stakedAmount == 0) {
            _default(msg.sender);
        }

        emit ETHCollateralWithdrawn(msg.sender, amount);
    }

    function liquidate(
        address borrower,
        uint256 repayAmount
    ) external nonZeroAddress(borrower) nonZeroAmount(repayAmount) {
        User storage user = _user(borrower);
        if (!_activePosition(borrower)) revert NoActivePosition();

        uint256 liquidationThreshold = (user.stakedAmount *
            LIQUIDATION_THRESHOLD) / PCT_DENOMINATOR;
        uint256 borrowedValueInUsd = (user.borrowedAssetAmount *
            uint256(getLatestPrice(user.borrowedAsset))) / WAD;

        if (borrowedValueInUsd < liquidationThreshold) {
            revert BorrowLimitExceeded(
                borrowedValueInUsd,
                liquidationThreshold
            );
        }

        // Transfer logic
        IERC20(user.borrowedAsset).approve(address(this), repayAmount);

        bool sucess = IERC20(user.borrowedAsset).transferFrom(
            msg.sender,
            address(this),
            repayAmount
        );

        if (!sucess)
            revert TransferFailed(user.borrowedAsset, msg.sender, repayAmount);

        // update state
        user.borrowedAssetAmount -= repayAmount;

        // transfer collateral to liquidator
        uint256 collateralToSeize = (repayAmount * WAD * WAD) /
            getLatestPrice(user.stakedAsset);

        if (collateralToSeize > user.stakedAmount) {
            collateralToSeize = user.stakedAmount;
        }

        user.stakedAmount -= collateralToSeize;

        // Transfer ETH
        (bool success, ) = address(msg.sender).call{value: collateralToSeize}(
            ""
        );
        if (!success)
            revert TransferFailed(address(0), msg.sender, collateralToSeize);

        if (user.borrowedAssetAmount == 0 && user.stakedAmount == 0) {
            _default(borrower);
        }
    }

    // ============ Internal helper Functions ============

    function _user(address user) internal view returns (User storage) {
        return users[user];
    }

    function _hasCollateral(address user) internal view returns (bool) {
        return users[user].stakedAmount > 0;
    }

    function _activePosition(address user) internal view returns (bool) {
        return users[user].borrowedAssetAmount > 0;
    }

    function _repayWithBorrowedAsset(
        address user,
        address token
    ) internal view returns (bool) {
        return (users[user].borrowedAsset == token);
    }

    function _default(address user) internal {
        User storage u = _user(user);
        u.borrowedAsset = address(0);
        u.borrowedAssetAmount = 0;
        u.stakedAsset = address(0);
        u.stakedAmount = 0;
    }

    function _getTokenDecimals(address token) internal view returns (uint8) {
        if (token == ethAddress) {
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

        bool sucess = erc.transfer(to, amount);

        if (!sucess) revert TokenTransferFailed(token, to, amount);
    }

    function _borrowableAmount(
        address user,
        address token
    ) internal view returns (uint256) {
        User storage u = _user(user);
        //  User must have collateral
        if (u.stakedAmount == 0) {
            revert NoCollateralProvided();
        }

        //  Ensure token has a valid oracle feed
        if (priceFeeds[token] == address(0)) {
            revert InvalidAsset(token);
        }

        //  get USD value of staked asset
        uint256 assetUsdValue = getUsdValue(u.stakedAsset, u.stakedAmount);
        //  Borrowing power = collateralUsd × LTV
        uint256 borrowingPower = (assetUsdValue * LTV) / PCT_DENOMINATOR;
        //  USD value of what the user already borrowed
        uint256 borrowedUsd = 0;
        if (u.borrowedAssetAmount > 0) {
            borrowedUsd = getUsdValue(u.borrowedAsset, u.borrowedAssetAmount);
        }
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
        uint256 borrowableToken = (availableToBorrowInUsd * WAD) / tokenPrice;
        return borrowableToken;
    }
}
