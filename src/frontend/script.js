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
import { MiniLendEventListener } from "./MiniLendEventListener.js";
//import { mainnet } from "https://esm.sh/viem/chains";

// ============ ABI ============
const miniLendAbi = await fetch("./abi/MiniLend.json").then((r) => r.json());
const mockUsdtAbi = await fetch("./abi/MockUsdt.json").then((r) => r.json());

// ============ DOM elements ============
const connectBtn = document.getElementById("connectBtn");
const loadBtn = document.getElementById("loadBtn");
const logEl = document.getElementById("log");
let mlAddr;
let tkAddr;
let logs = [];

let walletClient;
let publicClient;
let account;
let miniLend;
let mockUSDT;

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

const rpcUrl = anvil.rpcUrls.default.http[0];
const miniLendListener = new MiniLendEventListener(rpcUrl, mlAddr, anvil);
// Start listening to events
miniLendListener.start();

function log(msg) {
  logs.unshift(msg);

  // keep only last 10
  if (logs.length > 10) logs.pop();

  logEl.textContent = logs.join("\n");
}

window.clearLogs = function () {
  logs = [];
  logEl.textContent = "";
};

// shorten address
function shortenAddress(addr) {
  return addr.slice(0, 6) + "..." + addr.slice(-4);
}

// testing mode: always reset
localStorage.setItem("hideMetaMaskWarning", "false");

// ========\wallet Detection and connection ============
function detectWallet() {
  const hideWarning = localStorage.getItem("hideMetaMaskWarning");
  if (hideWarning === "true") return;

  if (!window.ethereum) {
    const modal = document.getElementById("walletModal");
    const message = document.getElementById("walletMessage");
    const installBtn = document.getElementById("installBtn");

    // detect mobile
    const isMobile = /android|iphone|ipad|mobile/i.test(navigator.userAgent);

    if (isMobile) {
      message.textContent = "MetaMask Mobile is required to use this DApp.";
      installBtn.onclick = () =>
        window.open("https://metamask.app.link/", "_blank");
    } else {
      message.textContent =
        "MetaMask browser extension is required to use this DApp.";
      installBtn.onclick = () =>
        window.open(
          "https://chromewebstore.google.com/detail/metamask/nkbihfbeogaeaoehlefnkodbefgpgknn",
          "_blank"
        );
    }

    modal.style.display = "flex";

    document.getElementById("closeBtn").onclick = () => {
      modal.style.display = "none";

      if (document.getElementById("dontShow").checked) {
        localStorage.setItem("hideMetaMaskWarning", "true");
      }
    };
  }
}

// ============ PopUp function ============
function showPopup(message, type = "info") {
  const popup = document.getElementById("popup");
  const popupMessage = document.getElementById("popupMessage");
  const popupContent = document.querySelector(".popup-content");

  popupMessage.textContent = message;

  // reset styles
  popupContent.classList.remove("popup-success", "popup-error");

  if (type === "success") popupContent.classList.add("popup-success");
  if (type === "error") popupContent.classList.add("popup-error");

  popup.classList.remove("hidden");
}

document.getElementById("popupClose").onclick = () => {
  document.getElementById("popup").classList.add("hidden");
};

// ============ Connect Wallet ============
connectBtn.onclick = async () => {
  if (!window.ethereum) {
    detectWallet();
    return;
  }

  try {
    walletClient = createWalletClient({
      chain: anvil,
      transport: custom(window.ethereum),
    });

    publicClient = createPublicClient({
      chain: anvil,
      transport: http(rpcUrl),
    });

    const addresses = await walletClient.requestAddresses();
    account = addresses[0];
    document.getElementById("account").textContent = "Connected";
    connectBtn.innerText = shortenAddress(account);
    log("Connected wallet: " + account);
  } catch (error) {
    log("Error: " + error.message);
    showPopup("Error: " + error.message, "error");
  }
};

// ============ Load Contracts ============
loadBtn.onclick = async () => {
  mlAddr = document.getElementById("miniLendAddress").value.trim();
  tkAddr = document.getElementById("tokenAddress").value.trim();

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
// ============ Stake ETH ============
document.getElementById("stakeBtn").onclick = async () => {
  const eth = document.getElementById("stakeInput").value;

  if (!eth || Number(eth) <= 0) {
    showPopup("Oga, Stake collateral must be > 0 ❌", "error");
    return;
  }

  try {
    await miniLend.write.stakeEth({
      account,
      value: parseEther(eth),
    });

    log("Staked " + eth + " ETH");
    showPopup("Staked " + eth + " ETH ✅", "success");
    refreshAccountStats();
  } catch (error) {
    console.error(error);

    let message = error.shortMessage || error.message || "Transaction failed";
    showPopup(message + " ❌", "error");
  }
};

// ============ Borrow Usdt ============

document.getElementById("borrowBtn").onclick = async () => {
  const v = document.getElementById("borrowInput").value;

  if (!v || Number(v) <= 0) {
    showPopup("Oga, borrow amount must be > 0 ❌", "error");
    return;
  }

  try {
    await miniLend.write.borrowUsd([parseUnits(v, 18)], { account });

    showPopup("Borrowed " + v + " USDT ✅", "success");
    refreshAccountStats();
  } catch (error) {
    console.error(error);

    let message = error.shortMessage || error.message || "Transaction failed";
    showPopup(message + " ❌", "error");
  }
};

// ============ Approve and Repay Usdt ============
document.getElementById("approveBtn").onclick = async () => {
  const v = document.getElementById("repayInput").value;

  if (!v || Number(v) <= 0) {
    showPopup("Approved amount must be > 0 ❌", "error");
    return;
  }

  try {
    await mockUSDT.write.approve([miniLend.address, parseUnits(v, 18)], {
      account,
    });

    log("Approved " + v + " USDT");
    showPopup("Approved " + v + " USDT ✅", "success");
  } catch (error) {
    console.error(error);

    let message = error.shortMessage || error.message || "Transaction failed";
    showPopup(message + " ❌", "error");
  }
};

// ============ Repay ============

document.getElementById("repayBtn").onclick = async () => {
  const v = document.getElementById("repayInput").value;

  if (!v || Number(v) <= 0) {
    showPopup("Repay amount must be > 0 ❌", "error");
    return;
  }

  try {
    await miniLend.write.repayUsd([parseUnits(v, 18)], { account });

    log("Repaid " + v + " USDT");
    showPopup("Repaid " + v + " USDT ✅", "success");
    refreshAccountStats();
  } catch (error) {
    console.error(error);

    let message = error.shortMessage || error.message || "Transaction failed";
    showPopup(message + " ❌", "error");
  }
};

// ============ Withdraw ETH ============
document.getElementById("withdrawBtn").onclick = async () => {
  const v = document.getElementById("withdrawInput").value;

  if (!v || Number(v) <= 0) {
    showPopup("Amount must be > 0 ❌", "error");
    return;
  }

  try {
    await miniLend.write.withdrawCollateralEth([parseEther(v)], { account });

    log("Withdrew " + v + " ETH");
    showPopup("Withdrew " + v + " ETH ✅", "success");
    refreshAccountStats();
  } catch (error) {
    console.error(error);

    let message = error.shortMessage || error.message || "Transaction failed";
    showPopup(message + " ❌", "error");
  }
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
