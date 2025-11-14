//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract MockUsdt is ERC20, Ownable(msg.sender) {
    address public minter;

    constructor(address _minter) ERC20("ERC20Mock", "MUsdt") {
        minter = _minter;
    }

    function mint(address account, uint256 amount) public {
        require(msg.sender == minter, "Sender is not the Minter");
        _mint(account, amount);
    }

    function setMinter(address _minter) external onlyOwner {
        minter = _minter;
    }

    function getMinter() public view returns(address){
        return(minter);
    }
}