"use client";

import { useState } from "react";
import { Camera, Fuel, Plus } from "lucide-react";
import { compressPhoto } from "./signature-pad";
import type { OutboxItem } from "./store";
import type { DriverExpense, RunData } from "./types";

const rs = (n: number) => `Rs. ${Number(n).toLocaleString("en-LK", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;

/** Expenses the driver paid from the cash they carry (not rejected by the office). */
export function expensesPaid(run: RunData) {
  return (run.driver_expenses ?? []).filter((x) => x.status !== "rejected").reduce((a, x) => a + Number(x.total), 0);
}

const STATUS: Record<string, string> = { pending_approval: "Waiting for office", approved: "Accepted", paid: "Accepted", rejected: "Refused — hand in this cash" };

export function RoadExpenses({ run, cashWithYou, onAdd }: {
  run: RunData; cashWithYou: number; onAdd: (item: OutboxItem, updated: RunData) => Promise<void>;
}) {
  const cats = run.expense_categories ?? [];
  const list = run.driver_expenses ?? [];
  const canAdd = ["loaded", "in_progress"].includes(run.run.status) && cats.length > 0;
  const [open, setOpen] = useState(false);
  const [cat, setCat] = useState(cats[0]?.code ?? "");
  const [amount, setAmount] = useState("");
  const [litres, setLitres] = useState("");
  const [odo, setOdo] = useState("");
  const [note, setNote] = useState("");
  const [photo, setPhoto] = useState("");
  const [msg, setMsg] = useState("");
  const [saving, setSaving] = useState(false);

  if (!canAdd && list.length === 0) return null;

  const save = async () => {
    setMsg("");
    const amt = Number(amount);
    if (!cat) return setMsg("Choose what it was for.");
    if (!(amt > 0)) return setMsg("Enter the amount you paid.");
    if (amt > cashWithYou) return setMsg("That is more than the cash you are carrying.");
    if (cat === "FUEL" && !(Number(litres) > 0)) return setMsg("Enter the litres.");
    setSaving(true);
    const id = crypto.randomUUID();
    const catName = cats.find((c) => c.code === cat)?.name ?? cat;
    const p: Record<string, unknown> = { category_code: cat, amount: amt, description: note.trim() || null };
    if (cat === "FUEL") { p.litres = Number(litres); if (odo) p.odometer_km = Math.round(Number(odo)); }
    const item: OutboxItem = {
      id, fn: "driver_record_expense", args: { p_run: run.run.id, p, p_client_txn_id: id }, run_id: run.run.id,
      label: `${catName} ${rs(amt)}`, created_at: new Date().toISOString(), status: "pending", attempts: 0,
      photo: photo ? { data_url: photo, path: `${run.run.id}/expense-${id}.jpg`, uploaded: false } : undefined,
    };
    const local: DriverExpense = { id, expense_no: null, category: catName, total: amt, status: "pending_approval", description: note.trim() || null, pending: true };
    await onAdd(item, { ...run, driver_expenses: [...list, local] });
    setSaving(false);
    setOpen(false);
    setAmount(""); setLitres(""); setOdo(""); setNote(""); setPhoto("");
  };

  return (
    <section className="rounded-2xl bg-white p-4 shadow-sm ring-1 ring-line">
      <div className="flex items-center justify-between">
        <h2 className="flex items-center gap-2 font-semibold"><Fuel className="h-4 w-4 text-ola-700" /> Road expenses</h2>
        {canAdd && !open && <button onClick={() => setOpen(true)} className="flex items-center gap-1 rounded-full bg-ola-100 px-3 py-1.5 text-sm font-medium text-ola-800"><Plus className="h-4 w-4" /> Add</button>}
      </div>
      <p className="mt-1 text-xs text-muted">Fuel, tolls, parking or a repair paid from the cash you carry. Keep the bill — the office checks it at check-in.</p>

      {list.length > 0 && (
        <ul className="mt-3 divide-y divide-line text-sm">
          {list.map((x) => (
            <li key={x.id} className="flex items-start justify-between gap-2 py-2">
              <span><span className="block font-medium">{x.category}</span>
                <span className={`block text-xs ${x.status === "rejected" ? "text-red-700" : "text-muted"}`}>{x.pending ? "Waiting to sync" : STATUS[x.status] ?? x.status}{x.description ? ` · ${x.description}` : ""}</span></span>
              <span className={`num whitespace-nowrap font-semibold ${x.status === "rejected" ? "line-through text-muted" : ""}`}>{rs(x.total)}</span>
            </li>
          ))}
        </ul>
      )}

      {open && (
        <div className="mt-3 space-y-3">
          <div className="grid grid-cols-2 gap-2">
            {cats.map((c) => (
              <button key={c.code} type="button" onClick={() => setCat(c.code)}
                className={`h-12 rounded-xl px-2 text-sm font-medium ring-1 ${cat === c.code ? "bg-ola-600 text-white ring-ola-600" : "bg-white ring-line"}`}>{c.name}</button>
            ))}
          </div>
          <label className="block text-sm font-medium">Amount paid (Rs.)
            <input type="number" inputMode="decimal" min={0} step="0.01" value={amount} onChange={(e) => setAmount(e.target.value)} className="mt-1 h-12 w-full rounded-xl border border-line px-3 text-lg" /></label>
          {cat === "FUEL" && (
            <div className="grid grid-cols-2 gap-2">
              <label className="block text-sm font-medium">Litres
                <input type="number" inputMode="decimal" min={0} step="0.01" value={litres} onChange={(e) => setLitres(e.target.value)} className="mt-1 h-12 w-full rounded-xl border border-line px-3" /></label>
              <label className="block text-sm font-medium">Odometer (km)
                <input type="number" inputMode="numeric" min={0} value={odo} onChange={(e) => setOdo(e.target.value)} className="mt-1 h-12 w-full rounded-xl border border-line px-3" /></label>
            </div>
          )}
          <label className="block text-sm font-medium">Note
            <input value={note} onChange={(e) => setNote(e.target.value)} placeholder="e.g. Ceypetco Kadawatha" className="mt-1 h-12 w-full rounded-xl border border-line px-3" /></label>
          <label className="flex h-24 cursor-pointer items-center justify-center gap-2 overflow-hidden rounded-xl border border-dashed border-line text-sm text-muted">
            {/* eslint-disable-next-line @next/next/no-img-element */}
            {photo ? <img src={photo} alt="Bill" className="h-full w-full object-cover" /> : <><Camera className="h-5 w-5" /> Photo of the bill (optional)</>}
            <input type="file" accept="image/*" capture="environment" className="sr-only" onChange={async (e) => { const f = e.target.files?.[0]; if (f) setPhoto(await compressPhoto(f)); }} />
          </label>
          {msg && <p className="text-sm text-red-700">{msg}</p>}
          <div className="grid grid-cols-2 gap-2">
            <button type="button" onClick={() => { setOpen(false); setMsg(""); }} className="h-12 rounded-xl font-medium ring-1 ring-line">Cancel</button>
            <button type="button" onClick={save} disabled={saving} className="h-12 rounded-xl bg-ola-600 font-semibold text-white disabled:opacity-60">Save</button>
          </div>
        </div>
      )}
    </section>
  );
}
