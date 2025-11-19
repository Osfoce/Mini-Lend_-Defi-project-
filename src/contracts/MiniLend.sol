//SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;
import "./MockUsdt.sol";

contract MiniLend {
    MockUsdt public mockusdt;

    constructor(address _mockusdtAddress) {
        mockusdt = MockUsdt(_mockusdtAddress);
    }

    struct User {
        uint256 StakedEth;
        uint256 BorrowedUsd;
    }

    mapping(address => User) public users;
    uint256 public constant LTV = 50;
    uint256 public constant ETHPriceInUSD = 2000e18;
    uint256 public constant LiquidationThreshold = 75;
    // address public USDAddress;

    event EthStaked(address indexed user, uint256 ETHamount);
    event USDRepaid(address indexed user, uint256 USDamount);
    event USDBorrowed(address indexed user, uint256 USDamount);
    event ETHCollateralWithdrawn(address indexed user, uint256 amount);

    function stakeETH() public payable {
        require(msg.value > 0, "No collateral provided");
        users[msg.sender].StakedEth += msg.value;
        emit EthStaked(msg.sender, msg.value);
    }

    function BorrowUSD(uint256 amount) public returns(uint256){
        User storage user = users[msg.sender];
        require(user.StakedEth > 0, "No ETH staked");
        require(amount > 0, "Chairman, we no dey play here na");
        uint256 maxBorrow = ((user.StakedEth * ETHPriceInUSD * LTV) / (100 * 1e18));
        uint256 seen = makeVisibleInt(maxBorrow);
        uint256 availableToBorrow = maxBorrow - user.BorrowedUsd;
        require(amount <= availableToBorrow, "Borrow amount exceeds LTV limit");

        if (howMuchYouCanStillBorrow(msg.sender) > 0){
            user.BorrowedUsd += amount;
        } else { revert("You have exceeded your borrow limit");}

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

    function howMuchYouCanStillBorrow(address user) public view returns(uint256){
        //User storage user = users[msg.sender];
        uint256 maxBorrow = ((users[user].StakedEth * ETHPriceInUSD * LTV) / (100 * 1e18 *1e18));
        if(((users[user].BorrowedUsd) / 1e18) >= maxBorrow) return 0;
        uint256 availableToBorrow = maxBorrow - ((users[user].BorrowedUsd) / 1e18);
        return(availableToBorrow);
    }

    function RepayUSD(uint256 amount) public {
        require(amount > 0, "Repay amount must be greater than zero");
        User storage user = users[msg.sender];
        require(user.BorrowedUsd > 0, "You didnt borrow usd");
        require(
            amount <= user.BorrowedUsd,
            "Over payment not supported currently"
        );
        // mockusdt.approve(address(this), amount);
        require(
            mockusdt.transferFrom(msg.sender, address(this), amount),
            "Transfer Failed"
        );

        user.BorrowedUsd -= amount;
        emit USDRepaid(msg.sender, amount);
    }

    function WithdrawCollateralETH(uint256 amount) public {
        // chech inputs
        require(amount > 0, "ETH amount must be greater than 0");
        User storage user = users[msg.sender];
        require(user.BorrowedUsd == 0, "Borrowed USDT not fully repaid");
        require(user.StakedEth >= amount, "You can't liquidate us bro, cut your coat accordingly");
        // update state
        user.StakedEth -= amount;
        //payable(msg.sender).transfer(amount);
        // Transfer ETH
        (bool success, ) = address(msg.sender).call{value: amount}("");
        require(success, "ETH transfer failed");

        emit ETHCollateralWithdrawn(msg.sender, amount);
    }

    function GetContractUsdBal() public view returns(uint256){
        return(mockusdt.balanceOf(address(this)));
    }

function makeVisibleInt(uint256 _int) public pure returns(uint256){
    return _int;
}


}
