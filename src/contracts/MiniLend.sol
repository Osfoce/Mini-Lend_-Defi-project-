//SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Address.sol";

contract MiniLend is ReentrancyGuard, Ownable(msg.sender) {
    using Address for address payable;

    /* ============ Errors ============ */
    error BorrowLimitExceeded(uint256 amount, uint256 availableToBorrow);
    error OverPaymentNotSupported(uint256 amountPaid, uint256 expectedAmount);
    error NotEnoughCollateral(uint256 collateralBalance, uint256 userInput);
    error BorrowedAmountNotFullyRepaid(uint256 balance);
    error TokenAlreadyApproved(address token);
    error TokenNotApproved(address token);
    error InvalidAddress(address addr);
    error NoCollateralProvided();
    error InvalidAmount();
    error NoUsdtBorrowed();
    error BadLtv(uint256 ltv);

    /* ============ Events ============ */
    event LtvUpdated(uint256 newLtv);
    event NewTokenApproved(address indexed token);
    event PriceFeedUpdated(address indexed token, address indexed feed);
    event MockUsdtAddressUpdated(address newAddress);
    event EthStaked(address indexed user, uint256 ethAmount);
    event USDRepaid(address indexed user, uint256 usdAmount);
    event USDBorrowed(address indexed user, uint256 usdAmount);
    event ETHCollateralWithdrawn(address indexed user, uint256 amount);

    /* ============ Structs ============ */
    struct User {
        uint256 stakedAsset;
        address borrowedAsset;
        uint256 borrowedAssetAmt;
    }

    /* ============ State ============ */
    mapping(address => User) public users;
    mapping(address => address) public priceFeeds;
    mapping(address => bool) public approvedTokens;
    mapping(address => uint256) public tokenindex;
    address[] public approvedTokenList;
    uint256 private LTV = 5000; // 50% LTV
    uint256 private constant WAD = 1e18;
    uint256 private constant PCT_DENOMINATOR = 10000; // for percentage calculations
    // uint256 private constant ETH_PRICE_IN_USD = 2000e18; // expect oracle integration later
    uint256 private constant LIQUIDATION_THRESHOLD = 7500;

    /* ============ Receive / Fallback ============ */
    receive() external payable {}

    fallback() external payable {}

    // =========== Admin Functions ============
    function setFeed(address token, address feed) external onlyOwner {
        priceFeeds[token] = feed;
        emit PriceFeedUpdated(token, feed);
    }

    function setLtv(uint256 _ltv) external onlyOwner {
        if (_ltv == 0 || _ltv > PCT_DENOMINATOR) revert BadLtv(_ltv);
        LTV = _ltv;
        emit LtvUpdated(_ltv);
    }

    function approveToken(address token) external onlyOwner {
        if (approvedTokens[token]) revert TokenAlreadyApproved(token);

        approvedTokens[token] = true;
        tokenindex[token] = approvedTokenList.length;
        approvedTokenList.push(token);

        emit NewTokenApproved(token);
    }

    function revokeTokenApproval(address token) external onlyOwner {
        if (!approvedTokens[token]) revert TokenNotApproved(token);

        approvedTokens[token] = false;

        // Remove from approvedTokenList
        uint256 index = tokenindex[token];
        uint256 lastIndex = approvedTokenList.length - 1;
        address lastToken = approvedTokenList[lastIndex];

        if (index != lastIndex) {
            // Move last element to removed position
            approvedTokenList[index] = lastToken;
            tokenindex[lastToken] = index;
        }

        approvedTokenList.pop();
        delete tokenindex[token];
    }

    // ========== Public view Functions ============

    function getLatestPrice(address token) public view returns (int256) {
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
        require(price > 0, "Invalid price data");
        require(answeredInRound >= roundId, "Stale round");
        require(
            updatedAt > 0 && (block.timestamp - updatedAt) < 1 hours,
            "Stale data"
        );

        uint256 decimals = priceFeed.decimals();
        require(decimals <= 18, "Too many decimals");
        return uint256(price) * 10 ** (18 - decimals);
    }

    function getContractsTokenBal(
        address token
    ) external view returns (uint256) {
        IERC20 erc = IERC20(token);
        return erc.balanceOf(address(this));
    }

    function getContractEthBal() external pure returns (uint256) {
        return address(this).balance;
    }

    function isTokenApproved(address token) external view returns (bool) {
        return approvedTokens[token];
    }

    function getApprovedTokensCount() external view returns (uint256) {
        return approvedTokenList.length;
    }

    // ========== Core Functions ============

    function stakeEth() public payable {
        if (msg.value > 0) {
            users[msg.sender].stakedAsset += msg.value;
        } else {
            revert NoCollateralProvided();
        }

        emit EthStaked(msg.sender, msg.value);
    }

    function borrowToken(address token, uint256 amount) external {
        if (amount == 0) revert InvalidAmount();
        if (token == address(0)) revert InvalidAddress(token);

        User storage user = users[msg.sender];

        if (user.stakedAsset == 0) revert NoCollateralProvided();

        // calculate max borrow
        uint256 availableToBorrow = _howMuchYouCanStillBorrow(
            msg.sender,
            token
        );
        if (availableToBorrow <= 0)
            revert BorrowLimitExceeded(amount, availableToBorrow);

        // update state
        user.borrowedAssetAmt += amount;
        user.borrowedAsset = token;

        // Transfer logic
        _ensureFundsAndTransfer(msg.sender, amount);

        emit USDBorrowed(msg.sender, amount);
    }

    function repayAsset(address token, uint256 amount) public {
        User storage user = users[msg.sender];
        if (amount == 0 || user.borrowedAssetAmt == 0) revert NoUsdtBorrowed();
        if (token != user.borrowedAsset)
            revert InvalidAddress(user.borrowedAsset);

        if (amount <= user.borrowedAssetAmt) {
            // mockusdt.approve(address(this), amount);
            require(
                IERC20(user.borrowedAsset).transferFrom(msg.sender, address(this), amount);
            );
        } else {
            revert OverPaymentNotSupported(amount, user.borrowedAssetAmt);
        }

        user.borrowedAssetAmt -= amount;
        

        emit USDRepaid(msg.sender, amount);
    }

    // collateral can be withdrawn only when borrowed usdt is fully repaid
    function withdrawCollateralEth(uint256 amount) public {
        User storage user = users[msg.sender];
        if (amount == 0 || user.borrowedAssetAmt != 0)
            revert BorrowedAmountNotFullyRepaid(user.borrowedAssetAmt);
        if (amount > user.stakedAsset)
            revert NotEnoughCollateral(user.stakedAsset, amount);

        // update state
        user.stakedAsset -= amount;
        //payable(msg.sender).transfer(amount);

        // Transfer ETH
        (bool success, ) = address(msg.sender).call{value: amount}("");
        require(success, "ETH transfer failed");

        emit ETHCollateralWithdrawn(msg.sender, amount);
    }

    // ============ Internal Functions ============

    function _ensureFundsAndTransfer(
        address token,
        address to,
        uint256 amount
    ) internal {
        IERC20 erc = IERC20(token);
        uint256 bal = erc.balanceOf(address(this));

        if (bal < amount) {
            revert InsufficientPoolBalance(bal, amount);
        }

        require(erc.transfer(to, amount), "Transfer failed");
    }

    function _howMuchYouCanStillBorrow(
        address user,
        address token
    ) internal view returns (uint256) {
        uint256 maxBorrow = ((users[user].stakedAsset *
            getLatestPrice(token) *
            LTV) / (PCT_DENOMINATOR * WAD * WAD));
        if (((users[user].borrowedAssetAmt) / WAD) >= maxBorrow) return 0;
        uint256 availableToBorrow = maxBorrow -
            ((users[user].borrowedAssetAmt) / WAD);
        return (availableToBorrow);
    }
}
