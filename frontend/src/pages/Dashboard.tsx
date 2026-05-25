import { useSystemData } from "../hooks/useSystemData";
import { StatCard } from "../components/StatCard";
import { fmtMCR } from "../lib/contracts";
import {
  LineChart, Line, XAxis, YAxis, Tooltip, ResponsiveContainer, ReferenceLine,
} from "recharts";
import { RefreshCw, AlertTriangle, Activity } from "lucide-react";

// ── Demo history data (replaced by on-chain events when connected) ────────────
const DEMO_MCR_HISTORY = Array.from({ length: 48 }, (_, i) => {
  const baseVol = 4500 + Math.sin(i * 0.3) * 2000 + (Math.random() - 0.5) * 500;
  const mcr = Math.min(160, Math.max(110, 110 + (baseVol - 2000) / 200));
  return {
    h:   `-${48 - i}h`,
    mcr: +mcr.toFixed(1),
    vol: +(baseVol / 100).toFixed(1),
  };
});

export function Dashboard() {
  const sys = useSystemData(15_000);

  const mcrPct  = (Number(sys.mcr) / 1e18 * 100).toFixed(1);
  const volPct  = (Number(sys.smoothedVol) / 100).toFixed(1);
  const tcrPct  = (Number(sys.tcrBPS) / 100).toFixed(1);
  const spPct   = (Number(sys.spDepthBPS) / 100).toFixed(1);

  const mcrHighlight =
    Number(mcrPct) >= 150 ? "red" :
    Number(mcrPct) >= 130 ? "yellow" : "green";

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold text-white">Protocol Dashboard</h1>
          <p className="text-sm text-gray-500 mt-0.5">
            EGARCH-adaptive MCR · Mezo Bitcoin Protocol
          </p>
        </div>
        <div className="flex items-center gap-3">
          {sys.circuitBreakerActive && (
            <span className="flex items-center gap-1.5 px-3 py-1.5 bg-red-950 border border-red-700 rounded-lg text-red-400 text-sm font-medium">
              <AlertTriangle className="w-4 h-4" />
              Circuit Breaker Active
            </span>
          )}
          {sys.hasPending && (
            <span className="flex items-center gap-1.5 px-3 py-1.5 bg-yellow-950 border border-yellow-700 rounded-lg text-yellow-400 text-sm font-medium">
              <Activity className="w-4 h-4" />
              Pending Proposal
            </span>
          )}
          <button
            onClick={sys.refresh}
            className="p-2 rounded-lg bg-gray-800 hover:bg-gray-700 text-gray-400 hover:text-white transition-colors"
          >
            <RefreshCw className={`w-4 h-4 ${sys.loading ? "animate-spin" : ""}`} />
          </button>
        </div>
      </div>

      {/* Key Stats */}
      <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
        {sys.hasPending ? (
          <div className="bg-gray-900 border border-blue-700 rounded-xl p-5">
            <p className="text-xs font-medium text-blue-400 uppercase tracking-wider mb-1">
              AdaptiveGuard Target MCR
            </p>
            <p className="text-3xl font-bold tabular-nums text-blue-300">
              {fmtMCR(sys.proposedMCR)}
            </p>
            <p className="text-xs text-gray-500 mt-1">
              Pending challenge window · Applied: {mcrPct}%
            </p>
          </div>
        ) : (
          <StatCard
            label="Current MCR"
            value={`${mcrPct}%`}
            sub="Minimum Collateral Ratio"
            highlight={mcrHighlight}
          />
        )}
        <StatCard
          label="EGARCH Vol (smoothed)"
          value={`${volPct}%`}
          sub={`Raw: ${(Number(sys.rawVol) / 100).toFixed(1)}%`}
          highlight={Number(volPct) > 80 ? "red" : Number(volPct) > 50 ? "yellow" : "blue"}
        />
        <StatCard
          label="System TCR"
          value={`${tcrPct}%`}
          sub="Total Collateral Ratio"
          highlight={Number(tcrPct) < 150 ? "red" : Number(tcrPct) < 200 ? "yellow" : "green"}
        />
        <StatCard
          label="SP Depth"
          value={`${spPct}%`}
          sub="Stability Pool / Total Debt"
          highlight={Number(spPct) < 10 ? "red" : Number(spPct) < 20 ? "yellow" : "green"}
        />
      </div>

      {/* MCR + Volatility Chart */}
      <div className="bg-gray-900 border border-gray-800 rounded-xl p-5">
        <h2 className="text-sm font-medium text-gray-400 uppercase tracking-wider mb-4">
          MCR & Volatility — 48h window (demo)
        </h2>
        <ResponsiveContainer width="100%" height={220}>
          <LineChart data={DEMO_MCR_HISTORY} margin={{ left: 0, right: 8 }}>
            <XAxis dataKey="h" tick={{ fill: "#6b7280", fontSize: 11 }} />
            <YAxis yAxisId="mcr"  domain={[108, 165]} tick={{ fill: "#6b7280", fontSize: 11 }} tickFormatter={v => `${v}%`} />
            <YAxis yAxisId="vol"  orientation="right" domain={[0, 100]} tick={{ fill: "#6b7280", fontSize: 11 }} tickFormatter={v => `${v}%`} />
            <Tooltip
              contentStyle={{ background: "#111827", border: "1px solid #374151", borderRadius: 8 }}
              labelStyle={{ color: "#9ca3af" }}
            />
            <ReferenceLine yAxisId="mcr" y={110} stroke="#374151" strokeDasharray="4 4" label={{ value: "110% min", fill: "#6b7280", fontSize: 10 }} />
            <ReferenceLine yAxisId="mcr" y={160} stroke="#374151" strokeDasharray="4 4" label={{ value: "160% max", fill: "#6b7280", fontSize: 10 }} />
            <Line yAxisId="mcr" type="monotone" dataKey="mcr" stroke="#34d399" strokeWidth={2} dot={false} name="MCR" />
            <Line yAxisId="vol" type="monotone" dataKey="vol" stroke="#60a5fa" strokeWidth={1.5} dot={false} name="Vol%" strokeDasharray="4 2" />
          </LineChart>
        </ResponsiveContainer>
      </div>

      {/* Oracle + Proposal Status */}
      <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
        <div className="bg-gray-900 border border-gray-800 rounded-xl p-5">
          <h2 className="text-sm font-medium text-gray-400 uppercase tracking-wider mb-3">Oracle Status</h2>
          <div className="space-y-2 text-sm">
            <Row label="Health" value={sys.oracleHealthy ? "✓ Healthy" : "✗ Stale"} valueClass={sys.oracleHealthy ? "text-green-400" : "text-red-400"} />
            <Row label="Smoothed Vol" value={`${(Number(sys.smoothedVol)/100).toFixed(2)}%`} />
            <Row label="Raw EGARCH Vol" value={`${(Number(sys.rawVol)/100).toFixed(2)}%`} />
            <Row label="Update #" value={sys.updateCount.toString()} />
            {sys.lastRefresh && <Row label="Last UI refresh" value={sys.lastRefresh.toLocaleTimeString()} />}
          </div>
        </div>

        <div className="bg-gray-900 border border-gray-800 rounded-xl p-5">
          <h2 className="text-sm font-medium text-gray-400 uppercase tracking-wider mb-3">Governance</h2>
          <div className="space-y-2 text-sm">
            <Row label="Pending proposal" value={sys.hasPending ? "Yes" : "None"} valueClass={sys.hasPending ? "text-yellow-400" : "text-gray-400"} />
            {sys.hasPending && <Row label="Proposed MCR" value={fmtMCR(sys.proposedMCR)} />}
            {sys.hasPending && <Row label="Deadline" value={new Date(Number(sys.proposalDeadline) * 1000).toLocaleTimeString()} />}
            <Row label="Circuit breaker" value={sys.circuitBreakerActive ? "ACTIVE" : "Off"} valueClass={sys.circuitBreakerActive ? "text-red-400" : "text-green-400"} />
            <Row label="Challenge window" value="1 hour" />
            <Row label="Rate limit" value="±5pp per epoch" />
          </div>
        </div>
      </div>

      {/* MCR Regime visualization */}
      <div className="bg-gray-900 border border-gray-800 rounded-xl p-5">
        <h2 className="text-sm font-medium text-gray-400 uppercase tracking-wider mb-4">Four-Regime MCR Mapping</h2>
        <div className="grid grid-cols-4 gap-2">
          {[
            { range: "< 30% vol", mcr: "110%", active: Number(volPct) < 30 },
            { range: "30–60% vol", mcr: "110–125%", active: Number(volPct) >= 30 && Number(volPct) < 60 },
            { range: "60–90% vol", mcr: "125–140%", active: Number(volPct) >= 60 && Number(volPct) < 90 },
            { range: "≥ 90% vol",  mcr: "140–160%", active: Number(volPct) >= 90 },
          ].map(r => (
            <div
              key={r.range}
              className={`rounded-lg p-3 border text-center transition-all ${
                r.active
                  ? "border-blue-500 bg-blue-950/40 text-blue-300"
                  : "border-gray-700 bg-gray-800/40 text-gray-500"
              }`}
            >
              <p className="text-xs font-medium">{r.range}</p>
              <p className={`text-lg font-bold mt-1 ${r.active ? "text-blue-200" : ""}`}>{r.mcr}</p>
            </div>
          ))}
        </div>
        <p className="text-xs text-gray-600 mt-3">
          Current smoothed volatility: <span className="text-gray-400">{volPct}%</span> →
          Base MCR: <span className="text-white font-medium">{mcrPct}%</span>
          {" (includes SP/TCR composite adjustments + rate limiting)"}
        </p>
      </div>
    </div>
  );
}

function Row({ label, value, valueClass = "text-white" }: { label: string; value: string; valueClass?: string }) {
  return (
    <div className="flex justify-between items-center py-1 border-b border-gray-800 last:border-0">
      <span className="text-gray-500">{label}</span>
      <span className={`font-mono font-medium ${valueClass}`}>{value}</span>
    </div>
  );
}
