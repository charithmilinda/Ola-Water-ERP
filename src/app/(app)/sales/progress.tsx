/** Small actual-vs-target bar. */
export function Progress({ actual, target, money = true }: { actual: number; target: number; money?: boolean }) {
  const p = target > 0 ? Math.min(100, Math.round((actual / target) * 100)) : 0;
  const fmt = (v: number) => (money ? v.toLocaleString("en-LK", { maximumFractionDigits: 0 }) : String(v));
  return (
    <div className="min-w-28">
      <div className="flex justify-between text-xs"><span className="num font-medium">{fmt(actual)}</span>
        <span className="text-muted">{target > 0 ? `${Math.round((actual / target) * 100)}% of ${fmt(target)}` : "no target"}</span></div>
      <div className="mt-1 h-1.5 rounded-full bg-line"><div className={`h-1.5 rounded-full ${p >= 100 ? "bg-emerald-500" : p >= 60 ? "bg-ola-500" : "bg-amber-500"}`} style={{ width: `${p}%` }} /></div>
    </div>
  );
}
