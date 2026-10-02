"use client";

import { Bar, BarChart, CartesianGrid, Legend, Line, LineChart, ResponsiveContainer, Tooltip, XAxis, YAxis } from "recharts";

const BLUE = "#1868d6";
const GREY = "#94a3b8";
const TEAL = "#0d9488";
const AMBER = "#d97706";
const COLORS = [BLUE, TEAL, AMBER, GREY];

const compact = (v: number) => (Math.abs(v) >= 1e6 ? `${(v / 1e6).toFixed(1)}M` : Math.abs(v) >= 1e3 ? `${Math.round(v / 1e3)}k` : String(Math.round(v)));
const full = (money: boolean) => (v: unknown) => {
  const n = Number(v);
  return money ? `Rs. ${n.toLocaleString("en-LK", { maximumFractionDigits: 0 })}` : n.toLocaleString("en-LK", { maximumFractionDigits: 1 });
};

export type Series = { key: string; label: string; dashed?: boolean };

/** Line chart over a category axis (months, weeks). */
export function TrendChart({ data, x, series, money = true, height = 260, unit }: {
  data: Record<string, unknown>[]; x: string; series: Series[]; money?: boolean; height?: number; unit?: string;
}) {
  return (
    <div style={{ height }} className="w-full">
      <ResponsiveContainer>
        <LineChart data={data} margin={{ top: 8, right: 12, bottom: 0, left: 0 }}>
          <CartesianGrid stroke="#e5e7eb" vertical={false} />
          <XAxis dataKey={x} tick={{ fontSize: 11, fill: "#64748b" }} tickLine={false} axisLine={{ stroke: "#e5e7eb" }} />
          <YAxis tick={{ fontSize: 11, fill: "#64748b" }} tickLine={false} axisLine={false} width={48}
            tickFormatter={(v) => `${compact(Number(v))}${unit ?? ""}`} />
          <Tooltip formatter={full(money)} contentStyle={{ borderRadius: 8, fontSize: 12 }} />
          {series.length > 1 && <Legend wrapperStyle={{ fontSize: 12 }} />}
          {series.map((s, i) => (
            <Line key={s.key} type="monotone" dataKey={s.key} name={s.label} stroke={COLORS[i % COLORS.length]} strokeWidth={2}
              strokeDasharray={s.dashed ? "5 4" : undefined} dot={false} activeDot={{ r: 4 }} isAnimationActive={false} />
          ))}
        </LineChart>
      </ResponsiveContainer>
    </div>
  );
}

/** Horizontal bars for a ranked list (top customers, routes, products). */
export function RankChart({ data, money = true, height }: { data: { name: string; value: number }[]; money?: boolean; height?: number }) {
  const h = height ?? Math.max(120, data.length * 32 + 24);
  return (
    <div style={{ height: h }} className="w-full">
      <ResponsiveContainer>
        <BarChart data={data} layout="vertical" margin={{ top: 4, right: 16, bottom: 4, left: 4 }}>
          <CartesianGrid stroke="#f1f5f9" horizontal={false} />
          <XAxis type="number" tick={{ fontSize: 11, fill: "#64748b" }} tickLine={false} axisLine={false} tickFormatter={(v) => compact(Number(v))} />
          <YAxis type="category" dataKey="name" width={130} tick={{ fontSize: 11, fill: "#334155" }} tickLine={false} axisLine={false} />
          <Tooltip formatter={full(money)} contentStyle={{ borderRadius: 8, fontSize: 12 }} cursor={{ fill: "#eef6ff" }} />
          <Bar dataKey="value" name={money ? "Sales" : "Value"} fill={BLUE} radius={[0, 4, 4, 0]} isAnimationActive={false} />
        </BarChart>
      </ResponsiveContainer>
    </div>
  );
}

/** Columns (e.g. weekly history). */
export function ColumnChart({ data, x, y, label, money = false, height = 200 }: {
  data: Record<string, unknown>[]; x: string; y: string; label: string; money?: boolean; height?: number;
}) {
  return (
    <div style={{ height }} className="w-full">
      <ResponsiveContainer>
        <BarChart data={data} margin={{ top: 8, right: 8, bottom: 0, left: 0 }}>
          <CartesianGrid stroke="#e5e7eb" vertical={false} />
          <XAxis dataKey={x} tick={{ fontSize: 11, fill: "#64748b" }} tickLine={false} axisLine={{ stroke: "#e5e7eb" }} />
          <YAxis tick={{ fontSize: 11, fill: "#64748b" }} tickLine={false} axisLine={false} width={40} tickFormatter={(v) => compact(Number(v))} />
          <Tooltip formatter={full(money)} contentStyle={{ borderRadius: 8, fontSize: 12 }} cursor={{ fill: "#eef6ff" }} />
          <Bar dataKey={y} name={label} fill={BLUE} radius={[4, 4, 0, 0]} isAnimationActive={false} />
        </BarChart>
      </ResponsiveContainer>
    </div>
  );
}

/** Tiny inline trend for table rows. */
export function Sparkline({ values }: { values: number[] }) {
  const max = Math.max(1, ...values);
  return (
    <span className="inline-flex h-6 items-end gap-px" aria-label={`Last ${values.length} weeks: ${values.join(", ")}`}>
      {values.map((v, i) => <span key={i} className="w-1.5 rounded-sm bg-ola-400" style={{ height: `${Math.max(6, (v / max) * 100)}%` }} />)}
    </span>
  );
}
