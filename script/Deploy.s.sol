// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// import {Script} from "forge-std/Script.sol";
// import {MockUsdt} from "../src/contracts/MockUsdt.sol";
// import {MiniLend} from "../src/contracts/MiniLend.sol";

// contract Deploy is Script {
//     function run() external returns (MiniLend, MockUsdt) {
//         // Load private key from .env
//         uint256 deployerKey = uint256(vm.envBytes32("PRIVATE_KEY"));

//         // Start broadcasting transactions using the deployer key
//         vm.startBroadcast(deployerKey);

//         // 1️⃣ Deploy MockUsdt first, pass deployer as minter temporarily
//         MockUsdt mock = new MockUsdt(msg.sender);

//         // 2️⃣ Deploy MiniLend with the address of MockUsdt
//         MiniLend miniLend = new MiniLend(address(mock));

//         // 3️⃣ Set MiniLend as the minter for MockUsdt
//         mock.setMinter(address(miniLend));

//         vm.stopBroadcast();

//         return (miniLend, mock);
//     }
// }
