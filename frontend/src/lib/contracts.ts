import { ethers } from "ethers";

// ── Addresses (override via VITE_ env vars or .env.local) ─────────────────────
export const ADDRESSES = {
  oracle:  import.meta.env.VITE_ORACLE_ADDRESS  ?? "",
  engine:  import.meta.env.VITE_ENGINE_ADDRESS  ?? "",
  adapter: import.meta.env.VITE_ADAPTER_ADDRESS ?? "",
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
