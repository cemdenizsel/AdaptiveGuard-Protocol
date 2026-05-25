import { ethers } from "ethers";

// ── Addresses (override via VITE_ env vars or .env.local) ─────────────────────
export const ADDRESSES = {
  oracle:       import.meta.env.VITE_ORACLE_ADDRESS         ?? "",
  engine:       import.meta.env.VITE_ENGINE_ADDRESS         ?? "",
  adapter:      import.meta.env.VITE_ADAPTER_ADDRESS        ?? "",
  borrowerOps:  import.meta.env.VITE_BORROWER_OPERATIONS    ?? "",
  troveManager: import.meta.env.VITE_TROVE_MANAGER          ?? "",
  musd:         import.meta.env.VITE_MUSD_ADDRESS           ?? "",
  hintHelpers:  import.meta.env.VITE_HINT_HELPERS           ?? "",
  sortedTroves: import.meta.env.VITE_SORTED_TROVES          ?? "",
};

// ── Minimal ABIs (only what the UI needs) ─────────────────────────────────────
export const ORACLE_ABI = [
  "function getVolatility() view returns (uint256 volBPS, uint256 updatedAt)",
  "function smoothedVolBPS() view returns (uint256)",
  "function rawVolBPS() view returns (uint256)",
  "function isHealthy() view returns (bool)",
  "function updateCount() view returns (uint256)",
];

export const ENGINE_ABI = [
  "function currentMCR() view returns (uint256)",
  "function hasPending() view returns (bool)",
  "function circuitBreakerUntil() view returns (uint256)",
  "function computeMCRFromVol(uint256 volBPS) view returns (uint256)",
  "function getSystemStatus() view returns (uint256 mcr, bool circuitBreakerActive, bool oracleHealthy, uint256 volBPS, uint256 proposalDeadline)",
  "function pendingProposal() view returns (uint256 proposedMCR, uint256 proposedAt, uint256 volBPS, address proposer)",
  "function applyPendingProposal()",
  "event MCRApplied(uint256 oldMCR, uint256 newMCR, uint256 volBPS)",
  "event MCRProposed(uint256 proposedMCR, uint256 volBPS, uint256 deadline, address proposer)",
];

export const ADAPTER_ABI = [
  "function getSystemStats() view returns (uint256 tcrBPS, uint256 spDepthBPS, uint256 btcPriceBPS)",
  "function checkPositionHealth(address owner) view returns (bool safe, uint256 currentCR, uint256 requiredMCR, uint8 riskLevel)",
  "function getTrove(address owner) view returns (tuple(uint256 collateralBTC18, uint256 debtMUSD18, bool active))",
  "function getActiveTroveOwners() view returns (address[])",
  "function simulatedBTCPrice() view returns (uint256)",
  "function simulatedSPBalance() view returns (uint256)",
  "function totalSimulatedDebt() view returns (uint256)",
  "function openSimulatedTrove(uint256 collateralBTC18, uint256 debtMUSD18)",
  "function closeSimulatedTrove()",
  "function addSimulatedCollateral(uint256 extraBTC18)",
  "function repaySimulatedDebt(uint256 repayAmount)",
  "function depositToSP(uint256 musdAmount)",
  "function isSimulated() view returns (bool)",
];

export const BORROWER_OPS_ABI = [
  "function openTrove(uint256 _debtAmount, address _upperHint, address _lowerHint) payable",
  "function addColl(address _upperHint, address _lowerHint) payable",
  "function withdrawColl(uint256 _amount, address _upperHint, address _lowerHint)",
  "function withdrawMUSD(uint256 _amount, address _upperHint, address _lowerHint)",
  "function repayMUSD(uint256 _amount, address _upperHint, address _lowerHint)",
  "function closeTrove()",
  "function stabilityPoolAddress() view returns (address)",
  "function getBorrowingFee(uint256 _debt) view returns (uint256)",
];

export const TROVE_MANAGER_ABI = [
  "function getTroveDebt(address _borrower) view returns (uint256)",
  "function getTroveColl(address _borrower) view returns (uint256)",
  "function getTroveStatus(address _borrower) view returns (uint256)",
  "function getCurrentICR(address _borrower, uint256 _price) view returns (uint256)",
  "function getTCR(uint256 _price) view returns (uint256)",
];

export const MUSD_ABI = [
  "function balanceOf(address account) view returns (uint256)",
  "function approve(address spender, uint256 amount) returns (bool)",
  "function allowance(address owner, address spender) view returns (uint256)",
];

export const HINT_HELPERS_ABI = [
  "function getApproxHint(uint256 _CR, uint256 _numTrials, uint256 _inputRandomSeed) view returns (address hintAddress, uint256 diff, uint256 latestRandomSeed)",
  "function computeNominalCR(uint256 _coll, uint256 _debt) pure returns (uint256)",
];

export const SORTED_TROVES_ABI = [
  "function findInsertPosition(uint256 _ICR, address _prevId, address _nextId) view returns (address upperHint, address lowerHint)",
];

export const STABILITY_POOL_ABI = [
  "function provideToSP(uint256 _amount, address _frontEndTag)",
  "function withdrawFromSP(uint256 _amount)",
  "function getCompoundedMUSDDeposit(address _depositor) view returns (uint256)",
  "function getTotalMUSDDeposits() view returns (uint256)",
];

// ── Provider / signer helpers ─────────────────────────────────────────────────
export function getProvider(): ethers.BrowserProvider | null {
  if (typeof window !== "undefined" && (window as any).ethereum) {
    return new ethers.BrowserProvider((window as any).ethereum);
  }
  return null;
}

export function getReadProvider(): ethers.JsonRpcProvider {
  const rpc = import.meta.env.VITE_RPC_URL ?? "http://127.0.0.1:8545";
  return new ethers.JsonRpcProvider(rpc);
}

export function engineContract(provider: ethers.ContractRunner) {
  return new ethers.Contract(ADDRESSES.engine, ENGINE_ABI, provider);
}

export function oracleContract(provider: ethers.ContractRunner) {
  return new ethers.Contract(ADDRESSES.oracle, ORACLE_ABI, provider);
}

export function adapterContract(provider: ethers.ContractRunner) {
  return new ethers.Contract(ADDRESSES.adapter, ADAPTER_ABI, provider);
}

export function borrowerOpsContract(runner: ethers.ContractRunner) {
  return new ethers.Contract(ADDRESSES.borrowerOps, BORROWER_OPS_ABI, runner);
}

export function troveManagerContract(runner: ethers.ContractRunner) {
  return new ethers.Contract(ADDRESSES.troveManager, TROVE_MANAGER_ABI, runner);
}

export function musdContract(runner: ethers.ContractRunner) {
  return new ethers.Contract(ADDRESSES.musd, MUSD_ABI, runner);
}

export function hintHelpersContract(runner: ethers.ContractRunner) {
  return new ethers.Contract(ADDRESSES.hintHelpers, HINT_HELPERS_ABI, runner);
}

export function sortedTrovesContract(runner: ethers.ContractRunner) {
  return new ethers.Contract(ADDRESSES.sortedTroves, SORTED_TROVES_ABI, runner);
}

export function stabilityPoolContract(addr: string, runner: ethers.ContractRunner) {
  return new ethers.Contract(addr, STABILITY_POOL_ABI, runner);
}

// ── Hint computation helper ───────────────────────────────────────────────────
const MUSD_GAS_COMPENSATION = ethers.parseEther("200");
const ZERO_ADDR = "0x0000000000000000000000000000000000000000";

export async function computeHints(
  provider: ethers.ContractRunner,
  collBTC: bigint,
  musdAmount: bigint,
): Promise<{ upper: string; lower: string }> {
  if (!ADDRESSES.hintHelpers || !ADDRESSES.sortedTroves) {
    return { upper: ZERO_ADDR, lower: ZERO_ADDR };
  }
  // Include borrowing fee in total debt for accurate NICR
  let fee = 0n;
  try {
    const bo = borrowerOpsContract(provider);
    fee = await bo.getBorrowingFee(musdAmount);
  } catch {}
  const totalDebt = musdAmount + fee + MUSD_GAS_COMPENSATION;
  // NICR = coll * 1e20 / debt  (no price, nominal ratio)
  const NICR = (collBTC * ethers.parseEther("100")) / totalDebt;
  const seed = BigInt(Math.floor(Math.random() * 1e9));
  const hh = hintHelpersContract(provider);
  const st = sortedTrovesContract(provider);
  const { hintAddress } = await hh.getApproxHint(NICR, 15n, seed);
  const [upper, lower] = await st.findInsertPosition(NICR, hintAddress, hintAddress);
  return { upper, lower };
}

// ── Formatting helpers ────────────────────────────────────────────────────────
export function fmtMCR(mcrWei: bigint): string {
  return (Number(mcrWei) / 1e18 * 100).toFixed(1) + "%";
}

export function fmtVol(volBPS: bigint): string {
  return (Number(volBPS) / 100).toFixed(1) + "%";
}

export function fmtBPS(bps: bigint): string {
  return (Number(bps) / 100).toFixed(1) + "%";
}

export function riskLabel(level: number): { text: string; color: string } {
  switch (level) {
    case 0: return { text: "Safe",         color: "text-green-400" };
    case 1: return { text: "Warning",      color: "text-yellow-400" };
    case 2: return { text: "At Risk",      color: "text-orange-400" };
    case 3: return { text: "Liquidatable", color: "text-red-500" };
    default:return { text: "Unknown",      color: "text-gray-400" };
  }
}
