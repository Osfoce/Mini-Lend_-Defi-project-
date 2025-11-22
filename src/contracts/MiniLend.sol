//SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;
import {MockUsdt} from "./MockUsdt.sol";

contract MiniLend {
    MockUsdt public mockusdt;

    constructor(address _mockusdtAddress) {
        mockusdt = MockUsdt(_mockusdtAddress);
    }

    struct User {
        uint256 stakedEth;
        uint256 borrowedUsdt;
    }

    mapping(address => User) public users;
    uint256 public constant LTV = 50;
    uint256 public constant ETH_PRICE_IN_USD = 2000e18;
    uint256 public constant LIQUIDATION_THRESHOLD = 75;
    // address public USDAddress;

    event EthStaked(address indexed user, uint256 ethAmount);
    event USDRepaid(address indexed user, uint256 usdAmount);
    event USDBorrowed(address indexed user, uint256 usdAmount);
    event ETHCollateralWithdrawn(address indexed user, uint256 amount);

    function stakeEth() public payable {
        require(msg.value > 0, "No collateral provided");
        users[msg.sender].stakedEth += msg.value;
        emit EthStaked(msg.sender, msg.value);
    }

    function borrowUsd(uint256 amount) public returns (uint256) {
        User storage user = users[msg.sender];
        require(user.stakedEth > 0, "No ETH staked");
        require(amount > 0, "Chairman, we no dey play here na");
        uint256 maxBorrow = ((user.stakedEth * ETH_PRICE_IN_USD * LTV) /
            (100 * 1e18));
        uint256 seen = makeVisibleInt(maxBorrow);
        uint256 availableToBorrow = maxBorrow - user.borrowedUsdt;
        require(amount <= availableToBorrow, "Borrow amount exceeds LTV limit");

        if (howMuchYouCanStillBorrow(msg.sender) > 0) {
            user.borrowedUsdt += amount;
        } else {
            revert("You have exceeded your borrow limit");
        }

        uint256 contractBalance = mockusdt.balanceOf(address(this));

        if (contractBalance >= amount) {
            require(mockusdt.transfer(msg.sender, amount), "Transfer failed");
        } else {
            uint256 shortfall = amount - contractBalance;
            if (contractBalance > 0) {
                require(
                    mockusdt.transfer(msg.sender, contractBalance),
                    "Transfer failed"
                );
            }
            mockusdt.mint(msg.sender, shortfall);
        }

        emit USDBorrowed(msg.sender, amount);
        return seen;
    }

    function howMuchYouCanStillBorrow(
        address user
    ) public view returns (uint256) {
        //User storage user = users[msg.sender];
        uint256 maxBorrow = ((users[user].stakedEth * ETH_PRICE_IN_USD * LTV) /
            (100 * 1e18 * 1e18));
        if (((users[user].borrowedUsdt) / 1e18) >= maxBorrow) return 0;
        uint256 availableToBorrow = maxBorrow -
            ((users[user].borrowedUsdt) / 1e18);
        return (availableToBorrow);
    }

    function repayUsd(uint256 amount) public {
        require(amount > 0, "Repay amount must be greater than zero");
        User storage user = users[msg.sender];
        require(user.borrowedUsdt > 0, "You didnt borrow usd");
        require(
            amount <= user.borrowedUsdt,
            "Over payment not supported currently"
        );
        // mockusdt.approve(address(this), amount);
        require(
            mockusdt.transferFrom(msg.sender, address(this), amount),
            "Transfer Failed"
        );

        user.borrowedUsdt -= amount;
        emit USDRepaid(msg.sender, amount);
    }

    function withdrawCollateralEth(uint256 amount) public {
        // chech inputs
        require(amount > 0, "ETH amount must be greater than 0");
        User storage user = users[msg.sender];
        require(user.borrowedUsdt == 0, "Borrowed USDT not fully repaid");
        require(
            user.stakedEth >= amount,
            "You can't liquidate us bro, cut your coat accordingly"
        );
        // update state
        user.stakedEth -= amount;
        //payable(msg.sender).transfer(amount);
        // Transfer ETH
        (bool success, ) = address(msg.sender).call{value: amount}("");
        require(success, "ETH transfer failed");

        emit ETHCollateralWithdrawn(msg.sender, amount);
    }

    function getContractUsdBal() public view returns (uint256) {
        return (mockusdt.balanceOf(address(this)));
    }

    function makeVisibleInt(uint256 _int) public pure returns (uint256) {
        return _int;
    }
}
