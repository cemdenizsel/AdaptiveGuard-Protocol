interface Props {
  label: string;
  value: string;
  sub?: string;
  highlight?: "green" | "yellow" | "red" | "blue" | "default";
  className?: string;
}

const COLORS = {
  green:   "text-green-400",
  yellow:  "text-yellow-400",
  red:     "text-red-400",
  blue:    "text-blue-400",
  default: "text-white",
};

export function StatCard({ label, value, sub, highlight = "default", className = "" }: Props) {
  return (
    <div className={`bg-gray-900 border border-gray-800 rounded-xl p-5 ${className}`}>
      <p className="text-xs font-medium text-gray-500 uppercase tracking-wider mb-1">{label}</p>
      <p className={`text-3xl font-bold tabular-nums ${COLORS[highlight]}`}>{value}</p>
      {sub && <p className="text-xs text-gray-500 mt-1">{sub}</p>}
    </div>
  );
}
