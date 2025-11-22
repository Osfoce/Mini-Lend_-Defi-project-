import {
  createWalletClient,
  createPublicClient,
  custom,
  parseEther,
  parseUnits,
  formatEther,
  formatUnits,
  getContract,
} from "https://esm.sh/viem";
import { http } from "https://esm.sh/viem";
//import { mainnet } from "https://esm.sh/viem/chains";

// ============ ABI ============
const miniLendAbi = await fetch("./abi/MiniLend.json").then((r) => r.json());
const mockUsdtAbi = await fetch("./abi/MockUsdt.json").then((r) => r.json());

// import miniLendAbi from "./abi/MiniLendAbi";
// import mockUsdtAbi from "./abi/MockUsdtAbi";

// ============ DOM elements ============
const connectBtn = document.getElementById("connectBtn");
const loadBtn = document.getElementById("loadBtn");
const logEl = document.getElementById("log");

let walletClient;
let publicClient;
let account;
let miniLend;
let mockUSDT;

// helper log
function log(msg) {
  logEl.textContent = msg + "\n" + logEl.textContent;
}

// shorten address
function shortenAddress(addr) {
  return addr.slice(0, 6) + "..." + addr.slice(-4);
}

// ============ Anvil Local Blockchain ============
const anvil = {
  id: 31337,
  name: "Anvil Local",
  network: "anvil",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: {
    default: { http: ["http://127.0.0.1:8545"] },
  },
};

connectBtn.onclick = async () => {
  if (!window.ethereum) {
    log("No Wallet Detected");
    document.getElementById("account").textContent =
      ".......WalletClient not found !!!  ";
    return;
  }

  try {
    walletClient = createWalletClient({
      chain: anvil,
      transport: custom(window.ethereum),
    });

    publicClient = createPublicClient({
      chain: anvil,
      transport: http("http://127.0.0.1:8545"),
    });

    const addresses = await walletClient.requestAddresses();
    account = addresses[0];
    document.getElementById("account").textContent = "Connected";
    connectBtn.innerText = shortenAddress(account);
    log("Connected wallet: " + account);
  } catch (error) {
    log("Error: " + error.message);
  }
};

// ============ Load Contracts ============
loadBtn.onclick = async () => {
  const mlAddr = document.getElementById("miniLendAddress").value.trim();
  const tkAddr = document.getElementById("tokenAddress").value.trim();

  miniLend = getContract({
    address: mlAddr,
    abi: miniLendAbi.abi,
    client: { public: publicClient, wallet: walletClient },
  });

  mockUSDT = getContract({
    address: tkAddr,
    abi: mockUsdtAbi.abi,
    client: { public: publicClient, wallet: walletClient },
  });

  log("Contracts loaded");
  refreshAccountStats();
};

// ============ Contract Actions ============
document.getElementById("stakeBtn").onclick = async () => {
  const eth = document.getElementById("stakeInput").value;

  await miniLend.write.stakeEth({
    account,
    value: parseEther(eth),
  });

  log("Staked " + eth + " ETH");
  refreshAccountStats();
};

document.getElementById("borrowBtn").onclick = async () => {
  const v = document.getElementById("borrowInput").value;
  await miniLend.write.borrowUsd([parseUnits(v, 18)], { account });

  log("Borrowed " + v + " USDT");
  refreshAccountStats();
};

document.getElementById("approveBtn").onclick = async () => {
  const v = document.getElementById("repayInput").value;
  await mockUSDT.write.approve([miniLend.address, parseUnits(v, 18)], {
    account,
  });

  log("Approved " + v + " USDT");
};

document.getElementById("repayBtn").onclick = async () => {
  const v = document.getElementById("repayInput").value;

  await miniLend.write.repayUsd([parseUnits(v, 18)], { account });

  log("Repaid " + v + " USDT");
  refreshAccountStats();
};

document.getElementById("withdrawBtn").onclick = async () => {
  const v = document.getElementById("withdrawInput").value;
  await miniLend.write.withdrawCollateralEth([parseEther(v)], { account });

  log("Withdrew " + v + " ETH");
  refreshAccountStats();
};

// ============ Refresh UI ============
async function refreshAccountStats() {
  if (!account) return;

  const user = await miniLend.read.users([account]);

  document.getElementById("stakedEth").textContent = formatEther(user[0]);
  document.getElementById("borrowedUsd").textContent = formatUnits(user[1], 18);

  const avail = await miniLend.read.howMuchYouCanStillBorrow([account]);
  document.getElementById("availableBorrow").textContent = avail;

  const contractUsdt = await mockUSDT.read.balanceOf([miniLend.address]);
  document.getElementById("contractUsdt").textContent = formatUnits(
    contractUsdt,
    18
  );

  const ethBalance = await publicClient.getBalance({
    address: miniLend.address, // or miniLend.target depending on your viem version
  });
  document.getElementById("contractEth").textContent = formatEther(ethBalance);
}
