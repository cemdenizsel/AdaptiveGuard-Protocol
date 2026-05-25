import { useState, useCallback, useEffect } from "react";
import { ethers } from "ethers";
import {
  getProvider,
  getReadProvider,
  adapterContract,
  borrowerOpsContract,
  troveManagerContract,
  musdContract,
  computeHints,
  ADDRESSES,
  riskLabel,
} from "../lib/contracts";
import { useSystemData } from "../hooks/useSystemData";
import { AlertTriangle, X, Plus, Minus, RefreshCw, ExternalLink } from "lucide-react";

// ── Constants ─────────────────────────────────────────────────────────────────
const MIN_MUSD_BORROW = ethers.parseEther("1800");
const MUSD_GAS_COMPENSATION = ethers.parseEther("200");
const ZERO_ADDR = "0x0000000000000000000000000000000000000000";
const MEZO_EXPLORER = "https://explorer.test.mezo.org/tx/";

// Trove status codes
const TROVE_STATUS = {
  0: "Non-existent",
  1: "Active",
  2: "Closed by Owner",
  3: "Closed by Liquidation",
  4: "Closed by Redemption",
} as const;

// ── Types ─────────────────────────────────────────────────────────────────────
interface SimulatedTroveState {
  active: boolean;
  collateralBTC: number;
  debtMUSD: number;
  cr: number;
  riskLevel: number;
}

interface RealTroveState {
  status: number;
  collBTC: number;
  debtMUSD: number;
  icr: number;
}

// ── Main component ────────────────────────────────────────────────────────────
export function CDPManager() {
  const sys = useSystemData(15_000);
  const isLive = Boolean(ADDRESSES.borrowerOps);

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex items-start justify-between">
        <div>
          <h1 className="text-2xl font-bold text-white">CDP Manager</h1>
          <p className="text-sm text-gray-500 mt-0.5">
            {isLive ? "Live Mezo Testnet" : "Simulated Demo Mode"}
          </p>
        </div>
        <span
          className={`px-3 py-1 rounded-full text-xs font-bold uppercase tracking-wider ${
            isLive
              ? "bg-green-900/60 text-green-300 border border-green-700"
              : "bg-yellow-900/60 text-yellow-300 border border-yellow-700"
          }`}
        >
          {isLive ? "LIVE" : "DEMO"}
        </span>
      </div>

      {/* Adaptive MCR banner — our key innovation */}
      <AdaptiveMCRBanner sys={sys} />

      {/* Mode-specific UI */}
      {isLive ? <LiveTroveUI sys={sys} /> : <SimulatedTroveUI sys={sys} />}
    </div>
  );
}

// ── Adaptive MCR Banner ───────────────────────────────────────────────────────
function AdaptiveMCRBanner({ sys }: { sys: ReturnType<typeof useSystemData> }) {
  const mcr = Number(sys.mcr) / 1e18;
  const mcrPct = (mcr * 100).toFixed(1);

  const mcrColor =
    mcr > 1.5 ? "text-red-400" : mcr > 1.35 ? "text-yellow-400" : "text-green-400";

  return (
    <div className="bg-gradient-to-r from-blue-950/60 to-purple-950/60 border border-blue-800/50 rounded-xl p-5">
      <div className="flex items-center gap-2 mb-2">
        <span className="text-xs font-bold uppercase tracking-widest text-blue-400">
          AdaptiveGuard Protocol
        </span>
        <span className="text-xs text-gray-500">— Volatility-Adjusted MCR</span>
      </div>
      <div className="flex items-end gap-6">
        <div>
          <p className="text-xs text-gray-500 mb-0.5">
            {sys.hasPending ? "AdaptiveGuard Target MCR" : "Current Adaptive MCR"}
          </p>
          <p className={`text-4xl font-bold font-mono ${sys.hasPending ? "text-blue-300" : mcrColor}`}>
            {sys.hasPending ? `${(Number(sys.proposedMCR) / 1e18 * 100).toFixed(1)}%` : `${mcrPct}%`}
          </p>
          <p className="text-xs text-gray-500 mt-1">
            {sys.hasPending
              ? `Pending challenge window · Applied: ${mcrPct}%`
              : "Minimum collateral ratio required by the protocol"}
          </p>
        </div>
        <div className="flex gap-6 text-sm pb-1">
          <div>
            <p className="text-gray-500">BTC Price</p>
            <p className="text-white font-mono font-bold">
              ${sys.btcPriceUSD.toLocaleString()}
            </p>
          </div>
          <div>
            <p className="text-gray-500">TCR</p>
            <p className="text-white font-mono font-bold">
              {sys.tcrBPS > 0n ? `${(Number(sys.tcrBPS) / 100).toFixed(1)}%` : "—"}
            </p>
          </div>
        </div>
      </div>
    </div>
  );
}

// ── Live Trove UI (real Mezo contracts) ───────────────────────────────────────
function LiveTroveUI({ sys }: { sys: ReturnType<typeof useSystemData> }) {
  const [trove, setTrove] = useState<RealTroveState | null>(null);
  const [musdBalance, setMusdBalance] = useState<number | null>(null);
  const [userAddr, setUserAddr] = useState<string | null>(null);

  // Open trove inputs
  const [coll, setColl] = useState("0.1");
  const [debt, setDebt] = useState("2000");

  // Add collateral / repay / withdraw inputs
  const [addCollAmt, setAddCollAmt] = useState("0.01");
  const [repayAmt, setRepayAmt] = useState("100");
  const [withdrawAmt, setWithdrawAmt] = useState("10");

  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [txHash, setTxHash] = useState<string | null>(null);

  const mcr = Number(sys.mcr) / 1e18;
  const btcPrice = sys.btcPriceUSD;

  // CR preview — must use total debt (borrow + ~0.5% fee + 200 gas comp) to match contract
  const collUSD = parseFloat(coll || "0") * btcPrice;
  const debtNum = parseFloat(debt || "0");
  const estimatedFee = debtNum * 0.005;
  const totalDebtPreview = debtNum + estimatedFee + 200;
  const crPreview = totalDebtPreview > 0 ? (collUSD / totalDebtPreview) * 100 : Infinity;
  const crColor =
    crPreview < mcr * 100 ? "text-red-400" : crPreview < mcr * 115 ? "text-yellow-400" : "text-green-400";

  const getSigner = useCallback(async () => {
    const provider = getProvider();
    if (!provider) throw new Error("No wallet connected. Install MetaMask.");
    await provider.send("eth_requestAccounts", []);
    return provider.getSigner();
  }, []);

  const fetchTroveData = useCallback(async () => {
    try {
      const signer = await getSigner();
      const addr = await signer.getAddress();
      setUserAddr(addr);

      const readProvider = getReadProvider();
      const tm = troveManagerContract(readProvider);
      const musd = musdContract(readProvider);

      const [statusRaw, collRaw, debtRaw, balRaw] = await Promise.all([
        tm.getTroveStatus(addr),
        tm.getTroveColl(addr),
        tm.getTroveDebt(addr),
        musd.balanceOf(addr),
      ]);

      const status = Number(statusRaw);
      const collBTC = Number(ethers.formatEther(collRaw));
      const debtMUSD = Number(ethers.formatEther(debtRaw));
      setMusdBalance(Number(ethers.formatEther(balRaw)));

      let icr = 0;
      if (status === 1 && btcPrice > 0) {
        const priceWei = BigInt(btcPrice) * BigInt(1e18);
        const icrRaw = await tm.getCurrentICR(addr, priceWei);
        icr = Number(icrRaw) / 1e16; // convert to percentage
      }

      setTrove({ status, collBTC, debtMUSD, icr });
    } catch (e: any) {
      setError(e.message ?? "Failed to fetch trove data");
    }
  }, [getSigner, btcPrice]);

  useEffect(() => {
    if (ADDRESSES.borrowerOps && btcPrice > 0) {
      fetchTroveData();
    }
  }, [fetchTroveData, btcPrice]);

  const sendTx = useCallback(
    async (fn: () => Promise<ethers.ContractTransactionResponse>) => {
      setLoading(true);
      setError(null);
      setTxHash(null);
      try {
        const tx = await fn();
        setTxHash(tx.hash);
        try {
          await tx.wait();
        } catch (waitErr: any) {
          // Mezo testnet RPC sometimes times out on receipt polling (HTTP 408).
          // The tx likely confirmed — refresh state and let the user verify on explorer.
          if (waitErr?.error?.data?.httpStatus === 408 || waitErr?.message?.includes("408")) {
            await fetchTroveData();
            return;
          }
          throw waitErr;
        }
        await fetchTroveData();
      } catch (e: any) {
        setError(e.reason ?? e.message ?? "Transaction failed");
      } finally {
        setLoading(false);
      }
    },
    [fetchTroveData],
  );

  const handleOpenTrove = useCallback(async () => {
    const signer = await getSigner();
    const collWei = ethers.parseEther(coll || "0");
    const musdWei = ethers.parseEther(debt || "0");

    if (collWei === 0n) {
      setError("Enter a BTC collateral amount greater than 0.");
      return;
    }
    if (musdWei < MIN_MUSD_BORROW) {
      setError(`Minimum borrow is 1800 MUSD. You entered ${debt} MUSD.`);
      return;
    }

    const readProvider = getReadProvider();
    const hints = await computeHints(readProvider, collWei, musdWei).catch(() => ({
      upper: ZERO_ADDR,
      lower: ZERO_ADDR,
    }));

    const ops = borrowerOpsContract(signer);
    await sendTx(() =>
      ops.openTrove(musdWei, hints.upper, hints.lower, {
        value: collWei,
      }),
    );
  }, [getSigner, coll, debt, sendTx]);

  const handleAddColl = useCallback(async () => {
    const signer = await getSigner();
    const collWei = ethers.parseEther(addCollAmt);
    const ops = borrowerOpsContract(signer);
    await sendTx(() => ops.addColl(ZERO_ADDR, ZERO_ADDR, { value: collWei }));
  }, [getSigner, addCollAmt, sendTx]);

  const handleRepay = useCallback(async () => {
    const signer = await getSigner();
    const repayWei = ethers.parseEther(repayAmt);

    const musd = musdContract(signer);
    setLoading(true);
    setError(null);
    try {
      // Step 1: approve
      const approveTx = await musd.approve(ADDRESSES.borrowerOps, repayWei);
      await approveTx.wait();
      // Step 2: repay
      const ops = borrowerOpsContract(signer);
      const tx = await ops.repayMUSD(repayWei, ZERO_ADDR, ZERO_ADDR);
      setTxHash(tx.hash);
      await tx.wait();
      await fetchTroveData();
    } catch (e: any) {
      setError(e.reason ?? e.message ?? "Repay failed");
    } finally {
      setLoading(false);
    }
  }, [getSigner, repayAmt, fetchTroveData]);

  const handleWithdrawMUSD = useCallback(async () => {
    if (!trove) return;
    const signer = await getSigner();
    const readProvider = getReadProvider();
    const withdrawWei = ethers.parseEther(withdrawAmt);

    const newCollWei = ethers.parseEther(trove.collBTC.toString());
    const hints = await computeHints(readProvider, newCollWei, withdrawWei).catch(() => ({
      upper: ZERO_ADDR,
      lower: ZERO_ADDR,
    }));

    const ops = borrowerOpsContract(signer);
    await sendTx(() => ops.withdrawMUSD(withdrawWei, hints.upper, hints.lower));
  }, [getSigner, trove, withdrawAmt, sendTx]);

  const handleCloseTrove = useCallback(async () => {
    if (!trove) return;

    // Net debt = total debt − gas compensation; user must hold this much MUSD
    const netDebtNeeded = trove.debtMUSD - Number(ethers.formatEther(MUSD_GAS_COMPENSATION));
    if (musdBalance !== null && musdBalance < netDebtNeeded) {
      const shortfall = (netDebtNeeded - musdBalance).toFixed(2);
      setError(
        `Insufficient MUSD to close. You need ${netDebtNeeded.toFixed(2)} MUSD but have ${musdBalance.toFixed(2)} MUSD. ` +
        `Borrow ${shortfall} more MUSD using "Withdraw MUSD" below, then try again.`
      );
      return;
    }

    const signer = await getSigner();
    const netDebtWei = ethers.parseEther(netDebtNeeded.toFixed(18));
    const musd = musdContract(signer);

    setLoading(true);
    setError(null);
    try {
      // Approve net debt amount (protocol returns gas compensation automatically)
      const approveTx = await musd.approve(ADDRESSES.borrowerOps, netDebtWei);
      await approveTx.wait();
      const ops = borrowerOpsContract(signer);
      const tx = await ops.closeTrove();
      setTxHash(tx.hash);
      await tx.wait();
      await fetchTroveData();
    } catch (e: any) {
      setError(e.reason ?? e.message ?? "Close trove failed");
    } finally {
      setLoading(false);
    }
  }, [getSigner, trove, musdBalance, fetchTroveData]);

  const isActiveTrove = trove?.status === 1;

  return (
    <div className="space-y-4">
      {/* Account info bar */}
      <div className="flex items-center justify-between bg-gray-900 border border-gray-800 rounded-lg px-4 py-3">
        <div className="flex gap-6 text-sm">
          {userAddr && (
            <span className="text-gray-500">
              Wallet:{" "}
              <span className="text-gray-300 font-mono">
                {userAddr.slice(0, 6)}…{userAddr.slice(-4)}
              </span>
            </span>
          )}
          {musdBalance !== null && (
            <span className="text-gray-500">
              MUSD Balance:{" "}
              <span className="text-white font-mono font-bold">
                {musdBalance.toLocaleString(undefined, { maximumFractionDigits: 2 })} MUSD
              </span>
            </span>
          )}
        </div>
        <button
          onClick={fetchTroveData}
          disabled={loading}
          className="flex items-center gap-1.5 px-3 py-1.5 bg-gray-800 hover:bg-gray-700 text-gray-300 rounded-lg text-xs font-medium transition-colors disabled:opacity-50"
        >
          <RefreshCw className="w-3 h-3" />
          Refresh
        </button>
      </div>

      {/* Active trove state */}
      {trove && isActiveTrove && (
        <div className="bg-gray-900 border border-gray-800 rounded-xl p-5 space-y-4">
          <h2 className="text-sm font-medium text-gray-400 uppercase tracking-wider">
            Your Active Trove
          </h2>
          <div className="grid grid-cols-3 gap-4 text-sm">
            <div>
              <p className="text-gray-500">Collateral</p>
              <p className="text-xl font-bold text-white">
                {trove.collBTC.toFixed(6)} BTC
              </p>
              <p className="text-gray-500">
                ${(trove.collBTC * btcPrice).toLocaleString()}
              </p>
            </div>
            <div>
              <p className="text-gray-500">Debt (incl. gas comp)</p>
              <p className="text-xl font-bold text-white">
                {trove.debtMUSD.toLocaleString(undefined, { maximumFractionDigits: 2 })} MUSD
              </p>
              <p className="text-gray-500 text-xs">
                +{Number(ethers.formatEther(MUSD_GAS_COMPENSATION))} MUSD gas compensation
              </p>
            </div>
            <div>
              <p className="text-gray-500">Collateral Ratio (ICR)</p>
              <p
                className={`text-xl font-bold ${
                  trove.icr < mcr * 100 ? "text-red-400" : "text-green-400"
                }`}
              >
                {trove.icr.toFixed(1)}%
              </p>
              <p className="text-xs text-gray-500">
                MCR:{" "}
                <span className="text-white">{(mcr * 100).toFixed(1)}%</span>
              </p>
            </div>
          </div>

          {/* Add collateral */}
          <div className="border-t border-gray-800 pt-4">
            <p className="text-xs text-gray-500 uppercase tracking-wide mb-2">
              Add Collateral
            </p>
            <div className="flex gap-2">
              <input
                type="number"
                min="0"
                step="0.001"
                value={addCollAmt}
                onChange={(e) => setAddCollAmt(e.target.value)}
                className="flex-1 bg-gray-800 border border-gray-700 rounded-lg px-3 py-2 text-white text-sm focus:border-blue-500 focus:outline-none"
                placeholder="BTC amount"
              />
              <button
                onClick={handleAddColl}
                disabled={loading}
                className="flex items-center gap-1.5 px-4 py-2 bg-blue-700 hover:bg-blue-600 disabled:bg-gray-700 disabled:text-gray-500 text-white rounded-lg text-sm font-medium transition-colors"
              >
                <Plus className="w-4 h-4" />
                Add Coll
              </button>
            </div>
          </div>

          {/* Repay MUSD */}
          <div className="border-t border-gray-800 pt-4">
            <p className="text-xs text-gray-500 uppercase tracking-wide mb-2">
              Repay MUSD
            </p>
            <div className="flex gap-2">
              <input
                type="number"
                min="0"
                step="100"
                value={repayAmt}
                onChange={(e) => setRepayAmt(e.target.value)}
                className="flex-1 bg-gray-800 border border-gray-700 rounded-lg px-3 py-2 text-white text-sm focus:border-blue-500 focus:outline-none"
                placeholder="MUSD amount"
              />
              <button
                onClick={handleRepay}
                disabled={loading}
                className="flex items-center gap-1.5 px-4 py-2 bg-purple-700 hover:bg-purple-600 disabled:bg-gray-700 disabled:text-gray-500 text-white rounded-lg text-sm font-medium transition-colors"
              >
                <Minus className="w-4 h-4" />
                Repay
              </button>
            </div>
            <p className="text-xs text-gray-500 mt-1">
              Will approve MUSD, then repay. Two transactions.
            </p>
          </div>

          {/* Withdraw MUSD (borrow more) */}
          <div className="border-t border-gray-800 pt-4">
            <p className="text-xs text-gray-500 uppercase tracking-wide mb-2">
              Withdraw MUSD (Borrow More)
            </p>
            <div className="flex gap-2">
              <input
                type="number"
                min="1"
                step="1"
                value={withdrawAmt}
                onChange={(e) => setWithdrawAmt(e.target.value)}
                className="flex-1 bg-gray-800 border border-gray-700 rounded-lg px-3 py-2 text-white text-sm focus:border-blue-500 focus:outline-none"
                placeholder="MUSD amount"
              />
              <button
                onClick={handleWithdrawMUSD}
                disabled={loading}
                className="flex items-center gap-1.5 px-4 py-2 bg-green-800 hover:bg-green-700 disabled:bg-gray-700 disabled:text-gray-500 text-white rounded-lg text-sm font-medium transition-colors"
              >
                <Plus className="w-4 h-4" />
                Borrow
              </button>
            </div>
            {trove && musdBalance !== null && (() => {
              const netDebtNeeded = trove.debtMUSD - Number(ethers.formatEther(MUSD_GAS_COMPENSATION));
              const shortfall = netDebtNeeded - musdBalance;
              return shortfall > 0 ? (
                <p className="text-xs text-orange-400 mt-1">
                  Gap: {shortfall.toFixed(2)} MUSD. Note: each borrow adds a fee — get MUSD from another wallet instead.
                </p>
              ) : null;
            })()}
          </div>

          {/* Close trove */}
          <div className="border-t border-gray-800 pt-4">
            <button
              onClick={handleCloseTrove}
              disabled={loading}
              className="flex items-center gap-2 px-4 py-2 bg-red-900 hover:bg-red-800 border border-red-700 text-red-300 rounded-lg text-sm font-medium disabled:opacity-50 transition-colors"
            >
              <X className="w-4 h-4" />
              Close Trove
            </button>
            <p className="text-xs text-gray-500 mt-1">
              Repays net debt (excl. 200 MUSD gas comp), returns collateral.
            </p>
          </div>
        </div>
      )}

      {/* Trove closed / non-existent info */}
      {trove && !isActiveTrove && trove.status !== 0 && (
        <div className="bg-gray-900 border border-gray-800 rounded-xl p-5">
          <p className="text-gray-400 text-sm">
            Trove status:{" "}
            <span className="text-white font-medium">
              {TROVE_STATUS[trove.status as keyof typeof TROVE_STATUS] ?? "Unknown"}
            </span>
          </p>
        </div>
      )}

      {/* Open trove form — shown when no active trove */}
      {(!trove || !isActiveTrove) && (
        <div className="bg-gray-900 border border-gray-800 rounded-xl p-5 space-y-4">
          <h2 className="text-sm font-medium text-gray-400 uppercase tracking-wider">
            Open Real Trove on Mezo
          </h2>

          <div className="grid grid-cols-2 gap-4">
            <div>
              <label className="text-xs text-gray-500 uppercase tracking-wide mb-1 block">
                BTC Collateral (msg.value)
              </label>
              <input
                type="number"
                min="0"
                step="0.001"
                value={coll}
                onChange={(e) => setColl(e.target.value)}
                className="w-full bg-gray-800 border border-gray-700 rounded-lg px-3 py-2 text-white focus:border-blue-500 focus:outline-none"
              />
              <p className="text-xs text-gray-600 mt-1">${collUSD.toLocaleString()} USD</p>
            </div>
            <div>
              <label className="text-xs text-gray-500 uppercase tracking-wide mb-1 block">
                MUSD to Borrow
              </label>
              <input
                type="number"
                min="1800"
                step="100"
                value={debt}
                onChange={(e) => setDebt(e.target.value)}
                className="w-full bg-gray-800 border border-gray-700 rounded-lg px-3 py-2 text-white focus:border-blue-500 focus:outline-none"
              />
              <p className="text-xs text-gray-600 mt-1">Min 1,800 MUSD</p>
            </div>
          </div>

          {/* CR preview */}
          <div className="bg-gray-800 rounded-lg px-4 py-3 flex items-center justify-between">
            <span className="text-sm text-gray-400">Real ICR (incl. fee + gas comp)</span>
            <span className={`text-lg font-bold font-mono ${crColor}`}>
              {isFinite(crPreview) ? `${crPreview.toFixed(1)}%` : "∞"}
            </span>
            <span className="text-sm text-gray-500">
              Adaptive MCR:{" "}
              <span className="text-white font-bold">{(mcr * 100).toFixed(1)}%</span>
            </span>
          </div>

          {debtNum > 0 && debtNum < 1800 && (
            <div className="flex items-center gap-2 text-sm text-yellow-400 bg-yellow-950/30 border border-yellow-900 rounded-lg px-3 py-2">
              <AlertTriangle className="w-4 h-4 flex-shrink-0" />
              Minimum borrow is 1,800 MUSD.
            </div>
          )}

          {crPreview < mcr * 100 && isFinite(crPreview) && (
            <div className="flex items-center gap-2 text-sm text-red-400 bg-red-950/30 border border-red-900 rounded-lg px-3 py-2">
              <AlertTriangle className="w-4 h-4 flex-shrink-0" />
              CR below adaptive MCR ({(mcr * 100).toFixed(1)}%). Increase collateral or reduce
              debt.
            </div>
          )}

          <button
            onClick={handleOpenTrove}
            disabled={loading || crPreview < mcr * 100 || debtNum < 1800}
            className="w-full py-2.5 bg-blue-700 hover:bg-blue-600 disabled:bg-gray-700 disabled:text-gray-500 text-white rounded-lg font-medium transition-colors"
          >
            {loading ? "Opening Trove…" : "Open Trove on Mezo"}
          </button>
          <p className="text-xs text-gray-500 text-center">
            ~0.1% borrowing fee · Sorted-list hints computed automatically
          </p>
        </div>
      )}

      {/* Feedback */}
      {error && (
        <div className="bg-red-950/40 border border-red-700 rounded-lg px-4 py-3 text-red-400 text-sm">
          {error}
        </div>
      )}
      {txHash && (
        <div className="bg-green-950/40 border border-green-700 rounded-lg px-4 py-3 text-green-400 text-sm flex items-center justify-between">
          <span>
            Tx:{" "}
            <span className="font-mono">
              {txHash.slice(0, 10)}…{txHash.slice(-8)}
            </span>
          </span>
          <a
            href={`${MEZO_EXPLORER}${txHash}`}
            target="_blank"
            rel="noopener noreferrer"
            className="flex items-center gap-1 text-green-300 hover:text-green-200 underline text-xs"
          >
            <ExternalLink className="w-3 h-3" />
            Mezo Explorer
          </a>
        </div>
      )}
    </div>
  );
}

// ── Simulated Trove UI (demo mode, uses MezoIntegrationAdapter) ───────────────
function SimulatedTroveUI({ sys }: { sys: ReturnType<typeof useSystemData> }) {
  const [trove, setTrove] = useState<SimulatedTroveState | null>(null);
  const [coll, setColl] = useState("1");
  const [debt, setDebt] = useState("25000");
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [txHash, setTxHash] = useState<string | null>(null);

  const btcPrice = sys.btcPriceUSD;
  const mcr = Number(sys.mcr) / 1e18;

  const collUSD = parseFloat(coll || "0") * btcPrice;
  const debtNum = parseFloat(debt || "0");
  const cr = debtNum > 0 ? (collUSD / debtNum) * 100 : Infinity;
  const crColor =
    cr < mcr * 100
      ? "text-red-400"
      : cr < mcr * 110
      ? "text-yellow-400"
      : "text-green-400";

  const getSigner = useCallback(async () => {
    const provider = getProvider();
    if (!provider) throw new Error("No wallet connected. Install MetaMask.");
    await provider.send("eth_requestAccounts", []);
    return provider.getSigner();
  }, []);

  const fetchTrove = useCallback(async () => {
    if (!ADDRESSES.adapter) return;
    try {
      const signer = await getSigner();
      const adapter = adapterContract(signer);
      const addr = await signer.getAddress();
      const t = await adapter.getTrove(addr);
      const [, crRaw, , riskLvl] = await adapter.checkPositionHealth(addr);

      if (t.active) {
        setTrove({
          active: true,
          collateralBTC: Number(ethers.formatEther(t.collateralBTC18)),
          debtMUSD: Number(ethers.formatEther(t.debtMUSD18)),
          cr: Number(crRaw) / 1e16,
          riskLevel: Number(riskLvl),
        });
      } else {
        setTrove({ active: false, collateralBTC: 0, debtMUSD: 0, cr: 0, riskLevel: 0 });
      }
    } catch {}
  }, [getSigner]);

  const sendTx = useCallback(
    async (fn: () => Promise<ethers.ContractTransactionResponse>) => {
      setLoading(true);
      setError(null);
      setTxHash(null);
      try {
        const tx = await fn();
        setTxHash(tx.hash);
        await tx.wait();
        await fetchTrove();
      } catch (e: any) {
        setError(e.reason ?? e.message ?? "Transaction failed");
      } finally {
        setLoading(false);
      }
    },
    [fetchTrove],
  );

  const openTrove = useCallback(async () => {
    const signer = await getSigner();
    const adapter = adapterContract(signer);
    const collWei = ethers.parseEther(coll);
    const debtWei = ethers.parseEther(debt);
    await sendTx(() => adapter.openSimulatedTrove(collWei, debtWei));
  }, [getSigner, coll, debt, sendTx]);

  const closeTrove = useCallback(async () => {
    const signer = await getSigner();
    const adapter = adapterContract(signer);
    await sendTx(() => adapter.closeSimulatedTrove());
  }, [getSigner, sendTx]);

  if (!ADDRESSES.adapter) {
    return <DemoNotice />;
  }

  return (
    <div className="space-y-4">
      {/* Demo mode notice */}
      <div className="bg-yellow-950/30 border border-yellow-900/50 rounded-lg px-4 py-3 text-yellow-400 text-sm flex items-center gap-2">
        <AlertTriangle className="w-4 h-4 flex-shrink-0" />
        Demo mode — using simulated troves via MezoIntegrationAdapter. Set{" "}
        <code className="bg-gray-800 px-1 rounded text-xs">VITE_BORROWER_OPERATIONS</code> to
        switch to live Mezo.
      </div>

      {/* Load trove button */}
      <div className="flex gap-4 text-sm">
        <button
          onClick={fetchTrove}
          className="px-4 py-2 bg-blue-700 hover:bg-blue-600 text-white rounded-lg text-sm font-medium"
        >
          Load My Trove
        </button>
      </div>

      {/* Active simulated trove */}
      {trove?.active && (
        <div className="bg-gray-900 border border-gray-800 rounded-xl p-5">
          <h2 className="text-sm font-medium text-gray-400 uppercase tracking-wider mb-3">
            Your Simulated Trove
          </h2>
          <div className="grid grid-cols-3 gap-4 text-sm">
            <div>
              <p className="text-gray-500">Collateral</p>
              <p className="text-xl font-bold text-white">
                {trove.collateralBTC.toFixed(4)} BTC
              </p>
              <p className="text-gray-500">
                ${(trove.collateralBTC * btcPrice).toLocaleString()}
              </p>
            </div>
            <div>
              <p className="text-gray-500">Debt</p>
              <p className="text-xl font-bold text-white">
                {trove.debtMUSD.toLocaleString()} MUSD
              </p>
            </div>
            <div>
              <p className="text-gray-500">Collateral Ratio</p>
              <p
                className={`text-xl font-bold ${
                  trove.cr < mcr * 100 ? "text-red-400" : "text-green-400"
                }`}
              >
                {trove.cr.toFixed(1)}%
              </p>
              <p className={`text-xs font-medium ${riskLabel(trove.riskLevel).color}`}>
                {riskLabel(trove.riskLevel).text}
              </p>
            </div>
          </div>
          <button
            onClick={closeTrove}
            disabled={loading}
            className="mt-4 flex items-center gap-2 px-4 py-2 bg-red-900 hover:bg-red-800 border border-red-700 text-red-300 rounded-lg text-sm font-medium disabled:opacity-50"
          >
            <X className="w-4 h-4" /> Close Simulated Trove
          </button>
        </div>
      )}

      {/* Open simulated trove */}
      {(!trove || !trove.active) && (
        <div className="bg-gray-900 border border-gray-800 rounded-xl p-5">
          <h2 className="text-sm font-medium text-gray-400 uppercase tracking-wider mb-4">
            Open Simulated Trove
          </h2>
          <div className="grid grid-cols-2 gap-4 mb-4">
            <div>
              <label className="text-xs text-gray-500 uppercase tracking-wide mb-1 block">
                BTC Collateral
              </label>
              <input
                type="number"
                min="0"
                step="0.01"
                value={coll}
                onChange={(e) => setColl(e.target.value)}
                className="w-full bg-gray-800 border border-gray-700 rounded-lg px-3 py-2 text-white focus:border-blue-500 focus:outline-none"
              />
              <p className="text-xs text-gray-600 mt-1">${collUSD.toLocaleString()} USD</p>
            </div>
            <div>
              <label className="text-xs text-gray-500 uppercase tracking-wide mb-1 block">
                MUSD to borrow
              </label>
              <input
                type="number"
                min="0"
                step="100"
                value={debt}
                onChange={(e) => setDebt(e.target.value)}
                className="w-full bg-gray-800 border border-gray-700 rounded-lg px-3 py-2 text-white focus:border-blue-500 focus:outline-none"
              />
            </div>
          </div>

          {/* CR preview */}
          <div className="bg-gray-800 rounded-lg px-4 py-3 mb-4 flex items-center justify-between">
            <span className="text-sm text-gray-400">Projected CR</span>
            <span className={`text-lg font-bold font-mono ${crColor}`}>
              {isFinite(cr) ? `${cr.toFixed(1)}%` : "∞"}
            </span>
            <span className="text-sm text-gray-500">
              Adaptive MCR:{" "}
              <span className="text-white">{(mcr * 100).toFixed(1)}%</span>
            </span>
          </div>

          {cr < mcr * 100 && isFinite(cr) && (
            <div className="flex items-center gap-2 text-sm text-red-400 bg-red-950/30 border border-red-900 rounded-lg px-3 py-2 mb-3">
              <AlertTriangle className="w-4 h-4 flex-shrink-0" />
              CR below adaptive MCR. Increase collateral or reduce debt.
            </div>
          )}

          <button
            onClick={openTrove}
            disabled={loading || cr < mcr * 100}
            className="w-full py-2.5 bg-blue-700 hover:bg-blue-600 disabled:bg-gray-700 disabled:text-gray-500 text-white rounded-lg font-medium transition-colors"
          >
            {loading ? "Opening…" : "Open Simulated Trove"}
          </button>
        </div>
      )}

      {/* Feedback */}
      {error && (
        <div className="bg-red-950/40 border border-red-700 rounded-lg px-4 py-3 text-red-400 text-sm">
          {error}
        </div>
      )}
      {txHash && (
        <div className="bg-green-950/40 border border-green-700 rounded-lg px-4 py-3 text-green-400 text-sm">
          Transaction:{" "}
          <span className="font-mono">
            {txHash.slice(0, 20)}…
          </span>
        </div>
      )}
    </div>
  );
}

// ── No-adapter placeholder ────────────────────────────────────────────────────
function DemoNotice() {
  return (
    <div className="bg-gray-900 border border-gray-800 rounded-xl p-8 text-center space-y-4">
      <h2 className="text-xl font-bold text-white">CDP Manager</h2>
      <p className="text-gray-400 max-w-md mx-auto">
        Set{" "}
        <code className="bg-gray-800 px-1.5 py-0.5 rounded text-blue-300">
          VITE_ADAPTER_ADDRESS
        </code>{" "}
        in{" "}
        <code className="bg-gray-800 px-1.5 py-0.5 rounded text-blue-300">.env.local</code>{" "}
        after deploying the contracts to interact with the simulated CDP system.
      </p>
      <pre className="bg-gray-800 rounded-lg p-4 text-left text-xs text-gray-300 max-w-lg mx-auto">
        {`# .env.local
VITE_RPC_URL=http://127.0.0.1:8545
VITE_ENGINE_ADDRESS=0x...
VITE_ORACLE_ADDRESS=0x...
VITE_ADAPTER_ADDRESS=0x...`}
      </pre>
    </div>
  );
}
