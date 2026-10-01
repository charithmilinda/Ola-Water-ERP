"use client";

import { useEffect, useMemo, useState } from "react";
import { ArrowLeft, Camera, MapPin, Minus, Navigation, Phone, Plus, X } from "lucide-react";
import { Scanner } from "./scanner";
import { SignaturePad, compressPhoto } from "./signature-pad";
import type { LocalReceipt, RunData, Stop } from "./types";
import type { OutboxItem } from "./store";
import { FAIL_REASONS } from "@/lib/labels";

const rs = (n: number) => `Rs. ${n.toLocaleString("en-LK", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
const phoneLocal = (e164: string) => e164.replace(/^\+94(\d{2})(\d{3})(\d{4})$/, "0$1 $2 $3");

type Ext = { company_id: string; qty: number };
type Mode = "deliver" | "fail";

export function StopView({
  run,
  stop,
  onBack,
  onComplete,
}: {
  run: RunData;
  stop: Stop;
  onBack: () => void;
  onComplete: (item: OutboxItem, receipt: LocalReceipt | null, newStatus: string, updatedRun: RunData) => void;
}) {
  const c = stop.customer;
  const own = run.own_company_id;
  const mainType = run.bottle_types[0]?.id ?? "";
  const externalCompanies = run.companies.filter((x) => !x.is_own);

  const [mode, setMode] = useState<Mode>("deliver");
  const [qty, setQty] = useState<Record<string, number>>(() => Object.fromEntries(stop.order.items.map((i) => [i.product_id, Number(i.qty)])));
  const [olaCount, setOlaCount] = useState<number>(Math.max(0, Number(stop.order.expected_ola_returns ?? 0)));
  const [scanned, setScanned] = useState<string[]>([]);
  const [ext, setExt] = useState<Ext[]>([]);
  const [method, setMethod] = useState<string>(c.credit_limit > 0 ? "credit" : "cash");
  const [amount, setAmount] = useState<string>("");
  const [tendered, setTendered] = useState<string>("");
  const [reference, setReference] = useState("");
  const [confirmKind, setConfirmKind] = useState<"signature" | "photo" | "none">(run.settings.require_confirmation ? "signature" : "none");
  const [signature, setSignature] = useState("");
  const [photo, setPhoto] = useState("");
  const [recipient, setRecipient] = useState("");
  const [notes, setNotes] = useState("");
  const [failReason, setFailReason] = useState(FAIL_REASONS[0]);
  const [reschedule, setReschedule] = useState("");
  const [gps, setGps] = useState<{ lat: number; lng: number } | null>(null);
  const [message, setMessage] = useState("");
  const [scanMsg, setScanMsg] = useState("");
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    navigator.geolocation?.getCurrentPosition((p) => setGps({ lat: +p.coords.latitude.toFixed(6), lng: +p.coords.longitude.toFixed(6) }), () => {}, { timeout: 8000, maximumAge: 60000 });
  }, []);

  const stockOnVehicle = (pid: string) => Number(run.vehicle_stock.find((s) => s.product_id === pid)?.qty ?? 0);
  const policyFor = (companyId: string) => c.external_policy ?? run.companies.find((x) => x.id === companyId)?.policy ?? run.settings.external_policy_default;
  const value = (companyId: string, typeId = mainType) => run.bottle_values.find((v) => v.company_id === companyId && v.bottle_type_id === typeId);

  // classify scans: OLA- labels count as OLA returns; EXT- labels as external bottles of the company in the tag
  const scannedOla = scanned.filter((s) => !s.startsWith("EXT-"));
  const scannedExt = scanned.filter((s) => s.startsWith("EXT-"));
  const extFromTags = scannedExt.reduce<Record<string, number>>((a, code) => {
    const co = run.companies.find((x) => x.code === code.split("-")[1]);
    if (co) a[co.id] = (a[co.id] ?? 0) + 1;
    return a;
  }, {});

  const estimate = useMemo(() => {
    const lines: LocalReceipt["lines"] = [];
    let total = 0;
    let issued = 0;
    for (const p of run.products) {
      const q = qty[p.id] ?? 0;
      if (q <= 0) continue;
      const oi = stop.order.items.find((i) => i.product_id === p.id);
      const price = oi ? Number(oi.unit_price) : Number(c.prices[p.id] ?? 0);
      const disc = oi && Number(oi.qty) > 0 ? Math.round((Number(oi.discount) * Math.min(q, Number(oi.qty))) / Number(oi.qty) * 100) / 100 : 0;
      const t = q * price - disc;
      lines.push({ description: p.name, qty: q, unit_price: price, discount: disc, total: t });
      total += t;
      if (p.is_returnable) issued += q;
    }
    const returnedOla = olaCount + scannedOla.length;
    const extAll: Record<string, number> = { ...extFromTags };
    ext.forEach((e) => (extAll[e.company_id] = (extAll[e.company_id] ?? 0) + e.qty));
    let credited = 0;
    let charge = 0;
    for (const [coId, n] of Object.entries(extAll)) {
      const pol = policyFor(coId);
      if (pol === "accept_one_for_one" || pol === "accept_with_charge") credited += n;
      if (pol === "accept_with_charge") {
        const ch = Number(value(coId)?.external_charge ?? 0) * n;
        if (ch > 0) {
          lines.push({ description: `${run.companies.find((x) => x.id === coId)?.name} bottle charge`, qty: n, unit_price: ch / n, total: ch });
          charge += ch;
        }
      }
    }
    const balance = Number(c.ola_bottles) + issued - returnedOla - credited;
    if (c.bottle_model === "deposit") {
      const dep = Number(value(own)?.deposit ?? 0);
      const held = Number(c.deposits_held[mainType] ?? 0);
      const delta = Math.max(balance, 0) - held;
      if (dep > 0 && delta !== 0) {
        lines.push({ description: delta > 0 ? "Bottle deposit" : "Deposit refund", qty: Math.abs(delta), unit_price: delta > 0 ? dep : -dep, total: delta * dep });
        total += delta * dep;
      }
    }
    total += charge;
    if (Number(stop.order.delivery_charge) > 0) {
      lines.push({ description: "Delivery charge", qty: 1, unit_price: Number(stop.order.delivery_charge), total: Number(stop.order.delivery_charge) });
      total += Number(stop.order.delivery_charge);
    }
    return { lines, total: Math.round(total * 100) / 100, issued, returnedOla, balance, extAll };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [qty, olaCount, scannedOla.length, ext, extFromTags, run, stop, c]);

  const payAmount = method === "credit" ? 0 : amount === "" ? Math.max(estimate.total, 0) : Number(amount);
  const change = method === "cash" && tendered !== "" ? Math.max(Number(tendered) - payAmount, 0) : 0;
  const overLimit = c.bottle_model === "loan" && estimate.balance > c.allowed_bottles;
  const overStock = run.products.some((p) => (qty[p.id] ?? 0) > stockOnVehicle(p.id));

  const addScan = (code: string) => {
    if (scanned.includes(code)) return setScanMsg(`${code} already scanned`);
    const co = code.startsWith("EXT-") ? run.companies.find((x) => x.code === code.split("-")[1]) : null;
    if (code.startsWith("EXT-") && co && policyFor(co.id) === "refuse") return setScanMsg(`${co.name} bottles are not accepted from this customer`);
    setScanMsg("");
    setScanned((s) => [code, ...s]);
  };

  const submit = async () => {
    setMessage("");
    if (mode === "deliver") {
      if (overStock) return setMessage("You are delivering more than is on the vehicle.");
      if (run.settings.require_confirmation && confirmKind === "none") return setMessage("A signature or photo is required.");
      if (confirmKind === "signature" && !signature) return setMessage("Ask the customer to sign, or choose another confirmation.");
      if (confirmKind === "photo" && !photo) return setMessage("Take a photo, or choose another confirmation.");
      if (["bank_transfer", "cheque"].includes(method) && !reference.trim()) return setMessage("Enter the reference number.");
    }
    setBusy(true);
    const id = crypto.randomUUID();
    const now = new Date().toISOString();
    const updated: RunData = JSON.parse(JSON.stringify(run));
    const st = updated.stops.find((s) => s.delivery_id === stop.delivery_id)!;

    if (mode === "fail") {
      const item: OutboxItem = {
        id, fn: "fail_delivery", run_id: run.run.id, delivery_id: stop.delivery_id, label: `${c.name} — not delivered`, created_at: now, status: "pending", attempts: 0,
        args: { p_delivery: stop.delivery_id, p_reason: failReason, p_notes: notes, p_reschedule_date: reschedule || null, p_gps: gps ?? {}, p_client_txn_id: id },
      };
      st.status = "failed";
      st.local = { pending: true, failed_reason: failReason };
      onComplete(item, null, "failed", updated);
      return;
    }

    const lines = run.products.filter((p) => (qty[p.id] ?? 0) > 0).map((p) => ({ product_id: p.id, qty: qty[p.id] }));
    const external = [
      ...scannedExt.map((code) => ({ company_id: run.companies.find((x) => x.code === code.split("-")[1])?.id, bottle_type_id: mainType, code })),
      ...ext.filter((e) => e.qty > 0).map((e) => ({ company_id: e.company_id, bottle_type_id: mainType, qty: e.qty })),
    ];
    const photoPath = photo ? `${run.run.id}/${stop.delivery_id}-${id}.jpg` : null;
    const item: OutboxItem = {
      id, fn: "complete_delivery", run_id: run.run.id, delivery_id: stop.delivery_id, label: `${c.name} — delivered`, created_at: now, status: "pending", attempts: 0,
      photo: photo && photoPath ? { data_url: photo, path: photoPath, uploaded: false } : undefined,
      args: {
        p_delivery: stop.delivery_id,
        p_client_txn_id: id,
        p: {
          lines, default_bottle_type_id: mainType,
          ola_returned_codes: scannedOla,
          ola_returned_counts: olaCount > 0 ? [{ bottle_type_id: mainType, qty: olaCount }] : [],
          external,
          payment: method === "credit" || payAmount <= 0 ? null : { method, amount: payAmount, reference, tendered: tendered ? Number(tendered) : null },
          confirmation: { method: confirmKind, signature_data: confirmKind === "signature" ? signature : null, photo_path: null, recipient_name: recipient },
          gps: gps ?? {}, notes, completed_at: now,
        },
      },
    };

    const extList = Object.entries(estimate.extAll).map(([coId, n]) => ({ company: run.companies.find((x) => x.id === coId)?.name ?? "", qty: n }));
    const receipt: LocalReceipt = {
      invoice_no: null, created_at: now, print_count: 0, subtotal_net: estimate.total, tax_total: 0, total: estimate.total,
      company: { name: run.company.name, vat_no: run.company.vat_no, footer: run.company.receipt_footer },
      customer: { name: c.name, customer_no: c.customer_no }, lines: estimate.lines, paid: payAmount, method: method === "credit" ? null : method,
      tendered: tendered ? Number(tendered) : null, change: change || null,
      outstanding: Number(c.outstanding) + estimate.total - payAmount,
      bottles: { issued: { [mainType]: estimate.issued }, returned: { [mainType]: estimate.returnedOla }, external: extList, balance: estimate.balance },
      pending_sync: true,
    };

    // optimistic local update of the cached run
    st.status = "delivered";
    st.local = { pending: true, receipt };
    for (const l of lines) {
      const vs = updated.vehicle_stock.find((s) => s.product_id === l.product_id);
      if (vs) vs.qty = Number(vs.qty) - l.qty;
    }
    if (method === "cash") updated.cash_collected = Number(updated.cash_collected) + payAmount;
    onComplete(item, receipt, "delivered", updated);
  };

  const navUrl = stop.address?.gps_lat
    ? `https://www.google.com/maps/dir/?api=1&destination=${stop.address.gps_lat},${stop.address.gps_lng}`
    : `https://www.google.com/maps/search/?api=1&query=${encodeURIComponent(`${stop.address?.address_line ?? ""} ${stop.address?.city ?? ""}`)}`;

  return (
    <div className="pb-32">
      <button onClick={onBack} className="mb-3 flex items-center gap-1 text-sm font-medium text-ola-700"><ArrowLeft className="h-4 w-4" /> Stops</button>

      <section className="rounded-2xl bg-white p-4 shadow-sm ring-1 ring-line">
        <p className="text-xs font-semibold uppercase tracking-wide text-muted">Stop {stop.stop_sequence} · {stop.order.order_no}</p>
        <h1 className="mt-1 text-xl font-semibold text-navy-900">{c.name}</h1>
        {c.company_name && <p className="text-sm text-muted">{c.company_name}</p>}
        {stop.address && (
          <p className="mt-2 flex gap-2 text-sm"><MapPin className="mt-0.5 h-4 w-4 shrink-0 text-muted" />{stop.address.address_line}{stop.address.city && `, ${stop.address.city}`}</p>
        )}
        {stop.address?.delivery_instructions && <p className="mt-1 rounded-lg bg-amber-50 px-3 py-2 text-sm text-amber-900">{stop.address.delivery_instructions}</p>}
        {stop.order.notes && <p className="mt-1 rounded-lg bg-ola-50 px-3 py-2 text-sm text-ola-900">{stop.order.notes}</p>}
        <div className="mt-3 grid grid-cols-2 gap-2">
          <a href={`tel:${c.phone}`} className="flex h-12 items-center justify-center gap-2 rounded-xl border border-line font-medium"><Phone className="h-4 w-4" /> {phoneLocal(c.phone)}</a>
          <a href={navUrl} target="_blank" rel="noopener" className="flex h-12 items-center justify-center gap-2 rounded-xl border border-line font-medium"><Navigation className="h-4 w-4" /> Navigate</a>
        </div>
        <div className="mt-3 grid grid-cols-3 gap-2 text-center text-xs">
          <div className="rounded-lg bg-surface p-2"><p className="text-muted">Holds</p><p className="num text-base font-semibold">{c.ola_bottles}</p></div>
          <div className="rounded-lg bg-surface p-2"><p className="text-muted">{c.bottle_model === "loan" ? "Limit" : "Model"}</p><p className="text-base font-semibold">{c.bottle_model === "loan" ? c.allowed_bottles : c.bottle_model === "deposit" ? "Deposit" : "—"}</p></div>
          <div className="rounded-lg bg-surface p-2"><p className="text-muted">Owes</p><p className={`num text-base font-semibold ${Number(c.outstanding) > 0 ? "text-red-700" : ""}`}>{Number(c.outstanding).toLocaleString("en-LK")}</p></div>
        </div>
      </section>

      <div className="mt-4 grid grid-cols-2 gap-2 rounded-xl bg-white p-1 ring-1 ring-line">
        <button onClick={() => setMode("deliver")} className={`h-11 rounded-lg font-semibold ${mode === "deliver" ? "bg-ola-600 text-white" : "text-navy-800"}`}>Deliver</button>
        <button onClick={() => setMode("fail")} className={`h-11 rounded-lg font-semibold ${mode === "fail" ? "bg-red-600 text-white" : "text-navy-800"}`}>Could not deliver</button>
      </div>

      {mode === "fail" ? (
        <section className="mt-4 space-y-3 rounded-2xl bg-white p-4 shadow-sm ring-1 ring-line">
          <label className="block text-sm font-medium">Reason
            <select value={failReason} onChange={(e) => setFailReason(e.target.value)} className="mt-1 h-12 w-full rounded-xl border border-line px-3">{FAIL_REASONS.map((r) => <option key={r}>{r}</option>)}</select>
          </label>
          <label className="block text-sm font-medium">Deliver on another day (optional)
            <input type="date" value={reschedule} onChange={(e) => setReschedule(e.target.value)} className="mt-1 h-12 w-full rounded-xl border border-line px-3" />
          </label>
          <label className="block text-sm font-medium">Notes
            <input value={notes} onChange={(e) => setNotes(e.target.value)} className="mt-1 h-12 w-full rounded-xl border border-line px-3" />
          </label>
        </section>
      ) : (
        <>
          <section className="mt-4 rounded-2xl bg-white p-4 shadow-sm ring-1 ring-line">
            <h2 className="mb-3 font-semibold">Deliver</h2>
            <div className="space-y-3">
              {run.products.filter((p) => (qty[p.id] ?? 0) > 0 || stop.order.items.some((i) => i.product_id === p.id) || (c.prices[p.id] !== undefined && stockOnVehicle(p.id) > 0)).map((p) => (
                <Stepper key={p.id} label={p.name} hint={`${stockOnVehicle(p.id)} on vehicle${c.prices[p.id] !== undefined ? ` · ${rs(Number(stop.order.items.find((i) => i.product_id === p.id)?.unit_price ?? c.prices[p.id]))}` : ""}`}
                  value={qty[p.id] ?? 0} max={stockOnVehicle(p.id)} onChange={(v) => setQty((q) => ({ ...q, [p.id]: v }))} />
              ))}
            </div>
          </section>

          <section className="mt-4 space-y-3 rounded-2xl bg-white p-4 shadow-sm ring-1 ring-line">
            <h2 className="font-semibold">Empty bottles collected</h2>
            <Stepper label="OLA bottles (not scanned)" hint={`Expected ${stop.order.expected_ola_returns}`} value={olaCount} onChange={setOlaCount} />
            <Scanner onScan={addScan} label="Scan bottle labels" />
            {scanMsg && <p className="rounded-lg bg-amber-50 px-3 py-2 text-sm text-amber-900">{scanMsg}</p>}
            {scanned.length > 0 && (
              <ul className="divide-y divide-line rounded-xl border border-line">
                {scanned.map((s) => (
                  <li key={s} className="flex items-center justify-between px-3 py-2 font-mono text-sm">
                    <span>{s} <span className="font-sans text-xs text-muted">{s.startsWith("EXT-") ? run.companies.find((x) => x.code === s.split("-")[1])?.name ?? "External" : "OLA"}</span></span>
                    <button onClick={() => setScanned((x) => x.filter((y) => y !== s))} aria-label={`Remove ${s}`}><X className="h-4 w-4 text-muted" /></button>
                  </li>
                ))}
              </ul>
            )}
            <div className="space-y-2 border-t border-line pt-3">
              <p className="text-sm font-medium">Other companies&apos; bottles without a tag</p>
              {externalCompanies.map((co) => {
                const pol = policyFor(co.id);
                const n = ext.find((e) => e.company_id === co.id)?.qty ?? 0;
                return pol === "refuse" ? null : (
                  <Stepper key={co.id} label={co.name} hint={pol === "accept_with_charge" ? `Charged ${rs(Number(value(co.id)?.external_charge ?? 0))} each` : pol === "accept_no_credit" ? "No credit given" : "Counts as a returned bottle"}
                    value={n} onChange={(v) => setExt((e) => [...e.filter((x) => x.company_id !== co.id), { company_id: co.id, qty: v }])} />
                );
              })}
              <p className="text-xs text-muted">Have tags? Stick an EXT- label on the bottle and scan it above instead.</p>
            </div>
          </section>

          <section className="mt-4 space-y-3 rounded-2xl bg-white p-4 shadow-sm ring-1 ring-line">
            <h2 className="font-semibold">Payment</h2>
            <div className="rounded-xl bg-surface p-3 text-sm">
              {estimate.lines.map((l, i) => (
                <div key={i} className="flex justify-between"><span>{l.qty} × {l.description}</span><span className="num">{rs(l.total)}</span></div>
              ))}
              <div className="mt-2 flex justify-between border-t border-line pt-2 text-base font-semibold"><span>Total</span><span className="num">{rs(estimate.total)}</span></div>
              <p className="mt-1 text-xs text-muted">Bottles after this stop: {estimate.balance}{overLimit && ` — over the limit of ${c.allowed_bottles}`}</p>
            </div>
            <div className="grid grid-cols-3 gap-2">
              {[["cash", "Cash"], ["card", "Card"], ["qr", "QR"], ["bank_transfer", "Bank"], ["cheque", "Cheque"], ["credit", "On account"]].map(([v, l]) => (
                <button key={v} type="button" onClick={() => setMethod(v)} disabled={v === "credit" && c.credit_limit <= 0}
                  className={`h-11 rounded-xl border text-sm font-medium disabled:opacity-40 ${method === v ? "border-ola-600 bg-ola-50 text-ola-800" : "border-line"}`}>{l}</button>
              ))}
            </div>
            {method !== "credit" && (
              <div className="grid grid-cols-2 gap-2">
                <label className="text-sm font-medium">Amount received
                  <input type="number" inputMode="decimal" value={amount} placeholder={String(Math.max(estimate.total, 0))} onChange={(e) => setAmount(e.target.value)} className="mt-1 h-12 w-full rounded-xl border border-line px-3 text-lg" />
                </label>
                {method === "cash" ? (
                  <label className="text-sm font-medium">Cash tendered
                    <input type="number" inputMode="decimal" value={tendered} onChange={(e) => setTendered(e.target.value)} className="mt-1 h-12 w-full rounded-xl border border-line px-3 text-lg" />
                    {change > 0 && <span className="mt-1 block text-sm font-semibold text-emerald-700">Change {rs(change)}</span>}
                  </label>
                ) : (
                  <label className="text-sm font-medium">Reference
                    <input value={reference} onChange={(e) => setReference(e.target.value)} className="mt-1 h-12 w-full rounded-xl border border-line px-3" />
                  </label>
                )}
              </div>
            )}
          </section>

          <section className="mt-4 space-y-3 rounded-2xl bg-white p-4 shadow-sm ring-1 ring-line">
            <h2 className="font-semibold">Confirmation</h2>
            <div className="grid grid-cols-3 gap-2">
              {(["signature", "photo", "none"] as const).map((k) => (
                <button key={k} type="button" onClick={() => setConfirmKind(k)} disabled={k === "none" && run.settings.require_confirmation}
                  className={`h-11 rounded-xl border text-sm font-medium capitalize disabled:opacity-40 ${confirmKind === k ? "border-ola-600 bg-ola-50 text-ola-800" : "border-line"}`}>{k === "none" ? "Skip" : k}</button>
              ))}
            </div>
            {confirmKind === "signature" && <SignaturePad onChange={setSignature} />}
            {confirmKind === "photo" && (
              <label className="flex h-32 cursor-pointer flex-col items-center justify-center gap-2 overflow-hidden rounded-xl border-2 border-dashed border-line bg-surface text-sm text-muted">
                {/* eslint-disable-next-line @next/next/no-img-element */}
                {photo ? <img src={photo} alt="Delivery photo" className="h-full w-full object-cover" /> : <><Camera className="h-6 w-6" /> Take a photo</>}
                <input type="file" accept="image/*" capture="environment" className="sr-only" onChange={async (e) => { const f = e.target.files?.[0]; if (f) setPhoto(await compressPhoto(f)); }} />
              </label>
            )}
            <input value={recipient} onChange={(e) => setRecipient(e.target.value)} placeholder="Received by (name)" className="h-12 w-full rounded-xl border border-line px-3" />
            <input value={notes} onChange={(e) => setNotes(e.target.value)} placeholder="Notes (optional)" className="h-12 w-full rounded-xl border border-line px-3" />
            <p className="text-xs text-muted">{gps ? `Location captured (${gps.lat}, ${gps.lng})` : "Location not available — the delivery is still recorded."}</p>
          </section>
        </>
      )}

      <div className="fixed inset-x-0 bottom-0 z-20 border-t border-line bg-white/95 p-3 backdrop-blur">
        {message && <p className="mb-2 text-sm text-red-700">{message}</p>}
        <button disabled={busy} onClick={submit}
          className={`h-14 w-full rounded-2xl text-lg font-semibold text-white disabled:opacity-50 ${mode === "fail" ? "bg-red-600" : "bg-ola-600"}`}>
          {mode === "fail" ? "Record as not delivered" : `Complete delivery · ${rs(estimate.total)}`}
        </button>
      </div>
    </div>
  );
}

function Stepper({ label, hint, value, onChange, max }: { label: string; hint?: string; value: number; onChange: (v: number) => void; max?: number }) {
  return (
    <div className="flex items-center justify-between gap-3">
      <div className="min-w-0">
        <p className="font-medium">{label}</p>
        {hint && <p className="text-xs text-muted">{hint}</p>}
      </div>
      <div className="flex shrink-0 items-center gap-2">
        <button type="button" onClick={() => onChange(Math.max(0, value - 1))} className="flex h-11 w-11 items-center justify-center rounded-xl border border-line" aria-label={`Fewer ${label}`}><Minus className="h-5 w-5" /></button>
        <input type="number" inputMode="numeric" value={value} min={0} onChange={(e) => onChange(Math.max(0, Number(e.target.value) || 0))}
          className={`num h-11 w-16 rounded-xl border text-center text-lg font-semibold ${max !== undefined && value > max ? "border-red-500 text-red-700" : "border-line"}`} aria-label={label} />
        <button type="button" onClick={() => onChange(value + 1)} className="flex h-11 w-11 items-center justify-center rounded-xl border border-line" aria-label={`More ${label}`}><Plus className="h-5 w-5" /></button>
      </div>
    </div>
  );
}
