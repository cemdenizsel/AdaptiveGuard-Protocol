import { useState, useCallback } from "react";
import { ethers } from "ethers";
import { getProvider, adapterContract, ADDRESSES, fmtMCR, riskLabel } from "../lib/contracts";
import { useSystemData } from "../hooks/useSystemData";
import { AlertTriangle, X } from "lucide-react";

interface TroveState {
  active: boolean;
  collateralBTC: number;
  debtMUSD: number;
  cr: number;
  riskLevel: number;
}

export function CDPManager() {
  const sys = useSystemData(15_000);
  const [trove, setTrove] = useState<TroveState | null>(null);
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
  const crColor = cr < mcr * 100 ? "text-red-400" : cr < mcr * 110 * 100 / 100 ? "text-yellow-400" : "text-green-400";

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

  const sendTx = useCallback(async (fn: () => Promise<ethers.ContractTransactionResponse>) => {
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
  }, [fetchTrove]);

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
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-bold text-white">CDP Manager</h1>
        <p className="text-sm text-gray-500 mt-0.5">Simulated Mezo troves — demo mode</p>
      </div>

      {/* System context */}
      <div className="flex gap-4 text-sm">
        <div className="bg-gray-900 border border-gray-800 rounded-lg px-4 py-3 flex gap-6">
          <span className="text-gray-500">MCR: <span className="text-white font-mono font-bold">{fmtMCR(sys.mcr)}</span></span>
          <span className="text-gray-500">BTC Price: <span className="text-white font-mono font-bold">${btcPrice.toLocaleString()}</span></span>
        </div>
        <button onClick={fetchTrove} className="px-4 py-2 bg-blue-700 hover:bg-blue-600 text-white rounded-lg text-sm font-medium">
          Load My Trove
        </button>
      </div>

      {/* Trove Status */}
      {trove?.active && (
        <div className="bg-gray-900 border border-gray-800 rounded-xl p-5">
          <h2 className="text-sm font-medium text-gray-400 uppercase tracking-wider mb-3">Your Trove</h2>
          <div className="grid grid-cols-3 gap-4 text-sm">
            <div>
              <p className="text-gray-500">Collateral</p>
              <p className="text-xl font-bold text-white">{trove.collateralBTC.toFixed(4)} BTC</p>
              <p className="text-gray-500">${(trove.collateralBTC * btcPrice).toLocaleString()}</p>
            </div>
            <div>
              <p className="text-gray-500">Debt</p>
              <p className="text-xl font-bold text-white">{trove.debtMUSD.toLocaleString()} MUSD</p>
            </div>
            <div>
              <p className="text-gray-500">Collateral Ratio</p>
              <p className={`text-xl font-bold ${trove.cr < mcr * 100 ? "text-red-400" : "text-green-400"}`}>
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
            <X className="w-4 h-4" /> Close Trove
          </button>
        </div>
      )}

      {/* Open Trove */}
      {(!trove || !trove.active) && (
        <div className="bg-gray-900 border border-gray-800 rounded-xl p-5">
          <h2 className="text-sm font-medium text-gray-400 uppercase tracking-wider mb-4">Open Simulated Trove</h2>
          <div className="grid grid-cols-2 gap-4 mb-4">
            <div>
              <label className="text-xs text-gray-500 uppercase tracking-wide mb-1 block">BTC Collateral</label>
              <input
                type="number" min="0" step="0.01"
                value={coll}
                onChange={e => setColl(e.target.value)}
                className="w-full bg-gray-800 border border-gray-700 rounded-lg px-3 py-2 text-white focus:border-blue-500 focus:outline-none"
              />
              <p className="text-xs text-gray-600 mt-1">${collUSD.toLocaleString()} USD</p>
            </div>
            <div>
              <label className="text-xs text-gray-500 uppercase tracking-wide mb-1 block">MUSD to borrow</label>
              <input
                type="number" min="0" step="100"
                value={debt}
                onChange={e => setDebt(e.target.value)}
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
              Min required: <span className="text-white">{(mcr * 100).toFixed(1)}%</span>
            </span>
          </div>

          {cr < mcr * 100 && isFinite(cr) && (
            <div className="flex items-center gap-2 text-sm text-red-400 bg-red-950/30 border border-red-900 rounded-lg px-3 py-2 mb-3">
              <AlertTriangle className="w-4 h-4 flex-shrink-0" />
              CR below MCR. Increase collateral or reduce debt.
            </div>
          )}

          <button
            onClick={openTrove}
            disabled={loading || cr < mcr * 100}
            className="w-full py-2.5 bg-blue-700 hover:bg-blue-600 disabled:bg-gray-700 disabled:text-gray-500 text-white rounded-lg font-medium transition-colors"
          >
            {loading ? "Opening…" : "Open Trove"}
          </button>
        </div>
      )}

      {/* Feedback */}
      {error && (
        <div className="bg-red-950/40 border border-red-700 rounded-lg px-4 py-3 text-red-400 text-sm">{error}</div>
      )}
      {txHash && (
        <div className="bg-green-950/40 border border-green-700 rounded-lg px-4 py-3 text-green-400 text-sm">
          Transaction: <span className="font-mono">{txHash.slice(0, 20)}…</span>
        </div>
      )}
    </div>
  );
}

function DemoNotice() {
  return (
    <div className="bg-gray-900 border border-gray-800 rounded-xl p-8 text-center space-y-4">
      <h2 className="text-xl font-bold text-white">CDP Manager</h2>
      <p className="text-gray-400 max-w-md mx-auto">
        Set <code className="bg-gray-800 px-1.5 py-0.5 rounded text-blue-300">VITE_ADAPTER_ADDRESS</code> in{" "}
        <code className="bg-gray-800 px-1.5 py-0.5 rounded text-blue-300">.env.local</code> after deploying
        the contracts to interact with the simulated CDP system.
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
