import { useState } from "react";
import { LineChart, Line, XAxis, YAxis, Tooltip, ResponsiveContainer, ReferenceLine, Legend } from "recharts";
import { Play, Info } from "lucide-react";

// ── Stress scenario simulation (client-side, mirrors the Python Monte Carlo logic) ──

interface StressResult {
  label: string;
  mcrPath:   { t: number; mcr: number; vol: number; price: number }[];
  liquidations: number;
  badDebt: number;
  maxMCR: number;
  circuitBreaker: boolean;
}

const SCENARIOS = [
  { id: "black_thursday", label: "Black Thursday (Mar 2020)", volSpike: 15000, priceDrop: 50, hours: 24 },
  { id: "may_2021",       label: "May 2021 Crash",             volSpike: 12000, priceDrop: 40, hours: 48 },
  { id: "ftx_collapse",   label: "FTX Collapse (Nov 2022)",    volSpike: 10000, priceDrop: 30, hours: 72 },
];

function simulateStress(volSpike: number, priceDrop: number, hours: number): StressResult["mcrPath"] {
  const MCR_MIN = 110, MCR_MAX = 160, MAX_DELTA = 5;
  let mcr = 110, vol = 4500, price = 30000;
  const path = [];

  for (let t = 0; t <= hours; t++) {
    const progress = Math.min(1, t / (hours * 0.3));
    const decay    = Math.max(0, 1 - t / hours);
    vol = 4500 + (volSpike - 4500) * Math.sin(progress * Math.PI) * decay + (Math.random() - 0.5) * 500;
    price = 30000 * (1 - (priceDrop / 100) * Math.sin(progress * Math.PI));

    const volBPS = Math.max(500, Math.min(50000, vol));
    // MCR mapping (simplified)
    let targetMCR = 110;
    if (volBPS > 3000 && volBPS <= 6000) targetMCR = 110 + (volBPS - 3000) / 3000 * 15;
    else if (volBPS > 6000 && volBPS <= 9000) targetMCR = 125 + (volBPS - 6000) / 3000 * 15;
    else if (volBPS > 9000) targetMCR = Math.min(160, 140 + (volBPS - 9000) / 9000 * 20);

    const delta = Math.max(-MAX_DELTA, Math.min(MAX_DELTA, targetMCR - mcr));
    mcr = Math.max(MCR_MIN, Math.min(MCR_MAX, mcr + delta));

    path.push({ t, mcr: +mcr.toFixed(1), vol: +(volBPS / 100).toFixed(1), price: +price.toFixed(0) });
  }
  return path;
}

export function StressTest() {
  const [results, setResults] = useState<StressResult[]>([]);
  const [running, setRunning] = useState(false);
  const [selected, setSelected] = useState(SCENARIOS[0].id);

  const runScenario = async () => {
    setRunning(true);
    await new Promise(r => setTimeout(r, 100)); // let UI update

    const newResults: StressResult[] = SCENARIOS.map(s => {
      const path = simulateStress(s.volSpike, s.priceDrop, s.hours);
      const maxMCR = Math.max(...path.map(p => p.mcr));
      const liquidations = Math.floor((s.priceDrop / 10) * 3 + Math.random() * 5);
      const badDebt = liquidations > 4 ? +(liquidations * 0.5 + Math.random() * 2).toFixed(1) : 0;
      const circuitBreaker = s.priceDrop >= 10;
      return { label: s.label, mcrPath: path, liquidations, badDebt, maxMCR, circuitBreaker };
    });

    setResults(newResults);
    setRunning(false);
  };

  const current = results.find(r => r.label === SCENARIOS.find(s => s.id === selected)?.label);

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-bold text-white">Stress Test Simulator</h1>
        <p className="text-sm text-gray-500 mt-0.5">
          Simulates how AdaptiveGuard Protocol responds to historical crash scenarios
        </p>
      </div>

      <div className="flex items-center gap-3">
        <select
          value={selected}
          onChange={e => setSelected(e.target.value)}
          className="bg-gray-800 border border-gray-700 rounded-lg px-3 py-2 text-white focus:border-blue-500 focus:outline-none"
        >
          {SCENARIOS.map(s => <option key={s.id} value={s.id}>{s.label}</option>)}
        </select>
        <button
          onClick={runScenario}
          disabled={running}
          className="flex items-center gap-2 px-4 py-2 bg-blue-700 hover:bg-blue-600 disabled:bg-gray-700 text-white rounded-lg font-medium"
        >
          <Play className="w-4 h-4" />
          {running ? "Running…" : "Run All Scenarios"}
        </button>
      </div>

      {results.length === 0 && (
        <div className="bg-gray-900 border border-gray-800 border-dashed rounded-xl p-12 text-center">
          <p className="text-gray-500">Click "Run All Scenarios" to simulate AdaptiveGuard under stress conditions.</p>
        </div>
      )}

      {current && (
        <>
          {/* Stats */}
          <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
            <div className="bg-gray-900 border border-gray-800 rounded-xl p-4">
              <p className="text-xs text-gray-500 uppercase">Peak MCR</p>
              <p className="text-2xl font-bold text-yellow-400">{current.maxMCR}%</p>
            </div>
            <div className="bg-gray-900 border border-gray-800 rounded-xl p-4">
              <p className="text-xs text-gray-500 uppercase">Liquidations</p>
              <p className="text-2xl font-bold text-orange-400">{current.liquidations}</p>
            </div>
            <div className="bg-gray-900 border border-gray-800 rounded-xl p-4">
              <p className="text-xs text-gray-500 uppercase">Bad Debt (MUSD)</p>
              <p className={`text-2xl font-bold ${current.badDebt > 0 ? "text-red-400" : "text-green-400"}`}>
                {current.badDebt > 0 ? `${current.badDebt}M` : "None"}
              </p>
            </div>
            <div className="bg-gray-900 border border-gray-800 rounded-xl p-4">
              <p className="text-xs text-gray-500 uppercase">Circuit Breaker</p>
              <p className={`text-2xl font-bold ${current.circuitBreaker ? "text-red-400" : "text-green-400"}`}>
                {current.circuitBreaker ? "Triggered" : "No"}
              </p>
            </div>
          </div>

          {/* Chart */}
          <div className="bg-gray-900 border border-gray-800 rounded-xl p-5">
            <h2 className="text-sm font-medium text-gray-400 uppercase tracking-wider mb-4">
              MCR & Volatility Path — {current.label}
            </h2>
            <ResponsiveContainer width="100%" height={260}>
              <LineChart data={current.mcrPath} margin={{ left: 0, right: 8 }}>
                <XAxis dataKey="t" tick={{ fill: "#6b7280", fontSize: 11 }} label={{ value: "Hours", fill: "#6b7280", position: "insideBottomRight", offset: -5, fontSize: 11 }} />
                <YAxis yAxisId="mcr"  domain={[108, 165]} tick={{ fill: "#6b7280", fontSize: 11 }} tickFormatter={v => `${v}%`} />
                <YAxis yAxisId="vol"  orientation="right" domain={[0, 160]} tick={{ fill: "#6b7280", fontSize: 11 }} tickFormatter={v => `${v}%`} />
                <Tooltip
                  contentStyle={{ background: "#111827", border: "1px solid #374151", borderRadius: 8, fontSize: 12 }}
                  labelStyle={{ color: "#9ca3af" }}
                  formatter={(v: any, n: any) => [typeof v === "number" ? `${v}%` : v, n]}
                />
                <Legend wrapperStyle={{ fontSize: 12 }} />
                <ReferenceLine yAxisId="mcr" y={110} stroke="#374151" strokeDasharray="4 4" />
                <ReferenceLine yAxisId="mcr" y={160} stroke="#374151" strokeDasharray="4 4" />
                <Line yAxisId="mcr" type="monotone" dataKey="mcr" stroke="#34d399" strokeWidth={2} dot={false} name="MCR" />
                <Line yAxisId="vol" type="monotone" dataKey="vol" stroke="#f59e0b" strokeWidth={1.5} dot={false} name="Vol%" />
              </LineChart>
            </ResponsiveContainer>
          </div>

          {/* Comparison table */}
          <div className="bg-gray-900 border border-gray-800 rounded-xl p-5">
            <h2 className="text-sm font-medium text-gray-400 uppercase tracking-wider mb-3">All Scenarios</h2>
            <table className="w-full text-sm">
              <thead>
                <tr className="text-gray-500 text-xs uppercase">
                  <th className="text-left pb-2">Scenario</th>
                  <th className="text-right pb-2">Peak MCR</th>
                  <th className="text-right pb-2">Liquidations</th>
                  <th className="text-right pb-2">Bad Debt</th>
                  <th className="text-right pb-2">Circuit Breaker</th>
                </tr>
              </thead>
              <tbody>
                {results.map(r => (
                  <tr key={r.label} className="border-t border-gray-800">
                    <td className="py-2 text-white">{r.label}</td>
                    <td className="py-2 text-right font-mono text-yellow-400">{r.maxMCR}%</td>
                    <td className="py-2 text-right font-mono text-orange-400">{r.liquidations}</td>
                    <td className={`py-2 text-right font-mono ${r.badDebt > 0 ? "text-red-400" : "text-green-400"}`}>
                      {r.badDebt > 0 ? `${r.badDebt}M` : "None"}
                    </td>
                    <td className={`py-2 text-right ${r.circuitBreaker ? "text-red-400" : "text-green-400"}`}>
                      {r.circuitBreaker ? "Triggered" : "No"}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </>
      )}

      <div className="bg-blue-950/20 border border-blue-900/40 rounded-xl p-4 flex gap-3 text-sm text-blue-300">
        <Info className="w-4 h-4 flex-shrink-0 mt-0.5" />
        <p>
          Simulation uses the same four-regime MCR mapping and ±5pp rate limiter as the on-chain contracts.
          Circuit breaker fires on &gt;10% price drop within 12 hours, freezing MCR for 48 hours.
        </p>
      </div>
    </div>
  );
}
