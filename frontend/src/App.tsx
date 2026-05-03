import { useState } from "react";
import { Shield, BarChart2, Settings, Activity } from "lucide-react";
import { Dashboard } from "./pages/Dashboard";
import { CDPManager } from "./pages/CDPManager";
import { StressTest } from "./pages/StressTest";

type Tab = "dashboard" | "cdp" | "stress";

const TABS: { id: Tab; label: string; Icon: React.ComponentType<{ className?: string }> }[] = [
  { id: "dashboard", label: "Dashboard",   Icon: BarChart2 },
  { id: "cdp",       label: "CDP Manager", Icon: Activity  },
  { id: "stress",    label: "Stress Test", Icon: Settings  },
];

export default function App() {
  const [tab, setTab] = useState<Tab>("dashboard");

  return (
    <div className="min-h-screen bg-gray-950">
      {/* Top nav */}
      <header className="border-b border-gray-800 bg-gray-950/95 backdrop-blur sticky top-0 z-10">
        <div className="max-w-6xl mx-auto px-4 h-14 flex items-center justify-between">
          <div className="flex items-center gap-2">
            <Shield className="w-5 h-5 text-blue-400" />
            <span className="font-bold text-white">AdaptiveGuard</span>
            <span className="text-xs px-1.5 py-0.5 bg-blue-950 text-blue-400 border border-blue-800 rounded font-medium">
              EGARCH MCR
            </span>
          </div>
          <nav className="flex gap-1">
            {TABS.map(({ id, label, Icon }) => (
              <button
                key={id}
                onClick={() => setTab(id)}
                className={`flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-sm transition-colors ${
                  tab === id
                    ? "bg-gray-800 text-white"
                    : "text-gray-400 hover:text-white hover:bg-gray-800/50"
                }`}
              >
                <Icon className="w-3.5 h-3.5" />
                {label}
              </button>
            ))}
          </nav>
          <div className="text-xs text-gray-600">Mezo Hackathon 2025</div>
        </div>
      </header>

      {/* Main content */}
      <main className="max-w-6xl mx-auto px-4 py-6">
        {tab === "dashboard" && <Dashboard />}
        {tab === "cdp"       && <CDPManager />}
        {tab === "stress"    && <StressTest />}
      </main>
    </div>
  );
}
