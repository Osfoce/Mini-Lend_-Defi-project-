import { createPublicClient, http, parseAbiItem } from "https://esm.sh/viem";
// import { mainnet, sepolia, localhost } from 'viem/chains';

export class MiniLendEventListener {
  constructor(rpcUrl, mlAddr, network) {
    this.client = createPublicClient({
      chain: network, // or your network
      transport: http(rpcUrl),
    });
    this.contractAddress = mlAddr;
    this.watchers = [];
    this.isListening = false;
  }

  async start() {
    if (this.isListening) {
      console.log("⚠️ Event listener already running");
      return;
    }

    console.log("🚀 Starting MiniLend event listener...");

    // Watch ALL your contract events
    const ethStakedWatcher = this.client.watchEvent({
      address: this.contractAddress,
      event: parseAbiItem(
        "event EthStaked(address indexed user, uint256 ethAmount)"
      ),
      onLogs: (logs) => {
        logs.forEach((log) => {
          console.log("💰 ETH Staked:", log.args);
          this.handleEthStaked(log.args);
        });
      },
    });

    const usdBorrowedWatcher = this.client.watchEvent({
      address: this.contractAddress,
      event: parseAbiItem(
        "event USDBorrowed(address indexed user, uint256 usdAmount)"
      ),
      onLogs: (logs) => {
        logs.forEach((log) => {
          console.log("💳 USD Borrowed:", log.args);
          this.handleUSDBorrowed(log.args);
        });
      },
    });

    const usdRepaidWatcher = this.client.watchEvent({
      address: this.contractAddress,
      event: parseAbiItem(
        "event USDRepaid(address indexed user, uint256 usdAmount)"
      ),
      onLogs: (logs) => {
        logs.forEach((log) => {
          console.log("✅ USD Repaid:", log.args);
          this.handleUSDRepaid(log.args);
        });
      },
    });

    const ethWithdrawnWatcher = this.client.watchEvent({
      address: this.contractAddress,
      event: parseAbiItem(
        "event ETHCollateralWithdrawn(address indexed user, uint256 amount)"
      ),
      onLogs: (logs) => {
        logs.forEach((log) => {
          console.log("↩️ ETH Withdrawn:", log.args);
          this.handleETHWithdrawn(log.args);
        });
      },
    });

    // Store all watchers for cleanup
    this.watchers.push(
      ethStakedWatcher,
      usdBorrowedWatcher,
      usdRepaidWatcher,
      ethWithdrawnWatcher
    );

    this.isListening = true;
    console.log("✅ Listening to all MiniLend events:", [
      "EthStaked",
      "USDBorrowed",
      "USDRepaid",
      "ETHCollateralWithdrawn",
    ]);
  }

  // Event handlers for each event type
  async handleEthStaked(args) {
    const { user, ethAmount } = args;
    console.log(`User ${user} staked ${ethAmount} ETH`);

    // Update database
    await this.updateUserStake(user, ethAmount);

    // Send notification
    await this.sendNotification(user, "eth_staked", { amount: ethAmount });
  }

  async handleUSDBorrowed(args) {
    const { user, usdAmount } = args;
    console.log(`User ${user} borrowed ${usdAmount} USD`);

    // Update loan in database
    await this.createLoanRecord(user, usdAmount);

    // Send notification
    await this.sendNotification(user, "usd_borrowed", { amount: usdAmount });
  }

  async handleUSDRepaid(args) {
    const { user, usdAmount } = args;
    console.log(`User ${user} repaid ${usdAmount} USD`);

    // Update loan status
    await this.updateLoanRepayment(user, usdAmount);

    // Send notification
    await this.sendNotification(user, "usd_repaid", { amount: usdAmount });
  }

  async handleETHWithdrawn(args) {
    const { user, amount } = args;
    console.log(`User ${user} withdrew ${amount} ETH collateral`);

    // Update collateral in database
    await this.updateCollateral(user, amount, "withdrawn");

    // Send notification
    await this.sendNotification(user, "eth_withdrawn", { amount });
  }

  // Database methods (implement based on your DB)
  async updateUserStake(user, amount) {
    // Update user's staked ETH in database
    console.log("💾 Updating user stake in database...");
  }

  async createLoanRecord(user, amount) {
    // Create new loan record in database
    console.log("💾 Creating loan record in database...");
  }

  async updateLoanRepayment(user, amount) {
    // Mark loan as (partially) repaid
    console.log("💾 Updating loan repayment in database...");
  }

  async updateCollateral(user, amount, action) {
    // Update user's collateral balance
    console.log("💾 Updating collateral in database...");
  }

  async sendNotification(user, eventType, data) {
    // Send email, push notification, webhook, etc.
    console.log(`📢 Sending ${eventType} notification to ${user}`);
  }

  stop() {
    this.watchers.forEach((unwatch) => unwatch());
    this.watchers = [];
    this.isListening = false;
    console.log("🛑 MiniLend event listener stopped");
  }
}
