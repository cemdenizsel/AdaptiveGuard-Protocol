import { useState, useEffect, useCallback } from "react";
import { getReadProvider, engineContract, oracleContract, adapterContract, ADDRESSES } from "../lib/contracts";

export interface SystemData {
  mcr: bigint;
  volBPS: bigint;
  smoothedVol: bigint;
  rawVol: bigint;
  oracleHealthy: boolean;
  circuitBreakerActive: boolean;
  circuitBreakerUntil: bigint;
  hasPending: boolean;
  proposalDeadline: bigint;
  proposedMCR: bigint;
  tcrBPS: bigint;
  spDepthBPS: bigint;
  btcPriceUSD: number;
  updateCount: bigint;
  loading: boolean;
  error: string | null;
  lastRefresh: Date | null;
}

const DEFAULT: SystemData = {
  mcr: 110n * 10n ** 16n,
  volBPS: 4500n,
  smoothedVol: 4500n,
  rawVol: 4500n,
  oracleHealthy: true,
  circuitBreakerActive: false,
  circuitBreakerUntil: 0n,
  hasPending: false,
  proposalDeadline: 0n,
  proposedMCR: 0n,
  tcrBPS: 25000n,
  spDepthBPS: 3000n,
  btcPriceUSD: 30000,
  updateCount: 0n,
  loading: true,
  error: null,
  lastRefresh: null,
};

export function useSystemData(refreshInterval = 15_000): SystemData & { refresh: () => void } {
  const [data, setData] = useState<SystemData>(DEFAULT);

  const fetch = useCallback(async () => {
    // If no addresses configured, return mock demo data
    if (!ADDRESSES.engine) {
      setData({
        ...DEFAULT,
        loading: false,
        lastRefresh: new Date(),
      });
      return;
    }

    try {
      const provider = getReadProvider();
      const engine  = engineContract(provider);
      const oracle  = oracleContract(provider);
      const adapter = ADDRESSES.adapter ? adapterContract(provider) : null;

      const [status, smoothedVol, rawVol, updateCount] = await Promise.all([
        engine.getSystemStatus(),
        oracle.smoothedVolBPS(),
        oracle.rawVolBPS(),
        oracle.updateCount(),
      ]);

      const [mcr, circuitBreakerActive, oracleHealthy, volBPS, proposalDeadline] = status;

      let proposedMCR = 0n;
      let hasPending = false;
      try {
        hasPending = await engine.hasPending();
        if (hasPending) {
          const p = await engine.pendingProposal();
          proposedMCR = p.proposedMCR;
        }
      } catch {}

      let tcrBPS = 25000n, spDepthBPS = 3000n, btcPriceBPS = 0n;
      if (adapter) {
        try {
          [tcrBPS, spDepthBPS, btcPriceBPS] = await adapter.getSystemStats();
        } catch {}
      }

      const circuitBreakerUntil = await engine.circuitBreakerUntil();

      setData({
        mcr,
        volBPS,
        smoothedVol,
        rawVol,
        oracleHealthy,
        circuitBreakerActive,
        circuitBreakerUntil,
        hasPending,
        proposalDeadline,
        proposedMCR,
        tcrBPS,
        spDepthBPS,
        btcPriceUSD: Number(btcPriceBPS) > 0 ? Number(btcPriceBPS) : 30000,
        updateCount,
        loading: false,
        error: null,
        lastRefresh: new Date(),
      });
    } catch (err: any) {
      setData(prev => ({ ...prev, loading: false, error: err.message }));
    }
  }, []);

  useEffect(() => {
    fetch();
    const id = setInterval(fetch, refreshInterval);
    return () => clearInterval(id);
  }, [fetch, refreshInterval]);

  return { ...data, refresh: fetch };
}
