"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { CheckCircle2, CloudOff, LogOut, Minus, Plus, Printer, RefreshCw, Search, TriangleAlert, UserRound, X } from "lucide-react";
import { browserClient } from "@/lib/supabase/browser";
import { useOutbox } from "@/lib/offline/use-outbox";
import type { OutboxItem } from "@/lib/offline/store";
import { Receipt80, type ReceiptData } from "@/components/receipt";
import { OlaMark } from "@/components/layout/logo";
import { Scanner } from "@/app/driver/scanner";
import { posStore } from "./store";
import type { PosBoot, PosCustomer, PosLocation } from "./types";

const rs = (n: number) => `Rs. ${Number(n).toLocaleString("en-LK", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
const METHODS: [string, string][] = [["cash", "Cash"], ["card", "Card"], ["qr", "QR"], ["bank_transfer", "Bank"], ["cheque", "Cheque"]];

type Line = { product_id: string; qty: number; discount: number };
type Pay = { method: string; amount: string; reference: string };
type View = "loading" | "choose" | "open" | "sell" | "receipt" | "close" | "closed";

async function rpc<T>(fn: string, args: Record<string, unknown>): Promise<{ data: T | null; error: string | null; offline: boolean }> {
  try {
    const { data, error } = await browserClient().rpc(fn, args);
    if (error) return { data: null, error: error.message, offline: !error.code && /fetch|network|Failed/i.test(error.message) };
    return { data: data as T, error: null, offline: false };
  } catch (e) {
    return { data: null, error: e instanceof Error ? e.message : "Network error", offline: true };
  }
}

export function PosApp({ userName, initialLocation, signOut }: { userName: string; initialLocation: string | null; signOut: () => Promise<void> }) {
  const [view, setView] = useState<View>("loading");
  const [locations, setLocations] = useState<PosLocation[]>([]);
  const [locId, setLocId] = useState<string | null>(initialLocation);
  const [boot, setBoot] = useState<PosBoot | null>(null);
  const [cached, setCached] = useState(false);
  const [error, setError] = useState("");
  const [receipt, setReceipt] = useState<(ReceiptData & { _txn?: string }) | null>(null);
  const [closeResult, setCloseResult] = useState<{ session_no: string; exceptions: number; lines: { item: string; expected: number; actual: number }[] } | null>(null);

  const { online, items, syncing, sync, enqueue, retry } = useOutbox(posStore, async (item, result) => {
    if (item.fn === "pos_sale") {
      await posStore.kv.set(`receipt:${item.id}`, result);
      setReceipt((r) => (r && r._txn === item.id ? { ...(result as ReceiptData), company: r.company, _txn: item.id, print_count: r.print_count } : r));
    }
  });
  const pending = items.filter((i) => i.status === "pending");
  const refused = items.filter((i) => i.status === "error");

  // ---------- loading ----------
  const loadBoot = useCallback(async (loc: string) => {
    const r = await rpc<PosBoot>("pos_bootstrap", { p_location: loc });
    let b: PosBoot | null = r.data;
    if (b) {
      // re-apply sales still waiting on this device
      const waiting = (await posStore.outbox.all()).filter((i) => i.fn === "pos_sale" && i.session_id === b!.session?.id);
      for (const w of waiting) {
        for (const l of ((w.args.p as { lines: Line[] }).lines ?? [])) {
          const pr = b.products.find((x) => x.id === l.product_id);
          if (pr) pr.stock -= l.qty;
        }
      }
      if (b.session) {
        const localSeq = (await posStore.kv.get<number>(`seq:${b.session.id}`)) ?? 0;
        b.session.next_seq = Math.max(b.session.next_seq, localSeq);
      }
      await posStore.kv.set(`boot:${loc}`, b);
      setCached(false);
    } else if (r.offline) {
      b = (await posStore.kv.get<PosBoot>(`boot:${loc}`)) ?? null;
      setCached(true);
      if (!b) setError("This till has not been used on this device yet. Connect to the internet once to set it up.");
    } else {
      setError(r.error ?? "Could not load the till");
    }
    setBoot(b);
    if (b) setView(b.session ? "sell" : "open");
  }, []);

  useEffect(() => {
    (async () => {
      const r = await rpc<PosLocation[]>("my_pos_locations", {});
      let locs = r.data;
      if (locs) await posStore.kv.set("locations", locs);
      else locs = (await posStore.kv.get<PosLocation[]>("locations")) ?? [];
      setLocations(locs);
      const remembered = initialLocation ?? (await posStore.kv.get<string>("location")) ?? null;
      const pick = locs.find((l) => l.id === remembered)?.id ?? (locs.length === 1 ? locs[0].id : null);
      if (pick) { setLocId(pick); await loadBoot(pick); } else setView("choose");
    })();
  }, [initialLocation, loadBoot]);

  useEffect(() => { if (!syncing && locId && view === "sell" && pending.length === 0 && online) loadBoot(locId); }, [syncing]); // eslint-disable-line react-hooks/exhaustive-deps

  const choose = async (id: string) => { setLocId(id); await posStore.kv.set("location", id); setView("loading"); await loadBoot(id); };

  // ---------- open / close ----------
  const openTill = async (float: number) => {
    if (!locId) return;
    const r = await rpc("open_pos_session", { p_location: locId, p_float: float, p_client_txn_id: crypto.randomUUID() });
    if (r.error) return setError(r.offline ? "Opening the till needs internet." : r.error);
    setError("");
    await loadBoot(locId);
  };

  const closeTill = async (p: Record<string, unknown>) => {
    if (!boot?.session) return;
    const r = await rpc<{ session_no: string; exceptions: number; lines: { item: string; expected: number; actual: number }[] }>(
      "close_pos_session", { p_session: boot.session.id, p, p_client_txn_id: crypto.randomUUID() });
    if (r.error) return setError(r.offline ? "Closing the till needs internet." : r.error);
    setError("");
    setCloseResult(r.data);
    setView("closed");
  };

  // ---------- a sale ----------
  const charge = async (args: { customer: PosCustomer | null; lines: Line[]; olaBack: number; codes: string[]; ext: Record<string, number>;
    payments: Pay[]; tendered: number | null; estimate: Estimate }) => {
    if (!boot?.session) return;
    const s = boot.session;
    const seq = s.next_seq;
    const id = crypto.randomUUID();
    const mainType = boot.bottle_types[0]?.id;
    const now = new Date().toISOString();
    const payments = args.payments.filter((p) => Number(p.amount) > 0).map((p) => ({ method: p.method, amount: Number(p.amount), reference: p.reference || null }));
    const item: OutboxItem = {
      id, fn: "pos_sale", session_id: s.id, label: `Receipt ${s.receipt_prefix}-${String(seq).padStart(4, "0")}`, created_at: now, status: "pending", attempts: 0,
      args: {
        p_session: s.id, p_client_txn_id: id,
        p: {
          customer_id: args.customer?.id ?? null, seq, sold_at: now, default_bottle_type_id: mainType,
          lines: args.lines.filter((l) => l.qty > 0),
          ola_returned_codes: args.codes,
          ola_returned_counts: args.olaBack > 0 ? [{ bottle_type_id: mainType, qty: args.olaBack }] : [],
          external: Object.entries(args.ext).filter(([, n]) => n > 0).map(([company_id, qty]) => ({ company_id, bottle_type_id: mainType, qty })),
          payments, tendered: args.tendered,
        },
      },
    };
    // update the device's copy straight away
    const nb: PosBoot = JSON.parse(JSON.stringify(boot));
    for (const l of args.lines) { const pr = nb.products.find((x) => x.id === l.product_id); if (pr) pr.stock -= l.qty; }
    if (!args.customer) {
      nb.walk_in_bottles = args.estimate.balanceAfter;
      if (mainType) nb.walk_in_deposits[mainType] = Math.max(args.estimate.balanceAfter, 0);
    }
    nb.session!.next_seq = seq + 1;
    nb.session!.sales += 1;
    nb.session!.cash_in += payments.filter((p) => p.method === "cash").reduce((a, p) => a + Math.min(p.amount, Math.max(args.estimate.total, 0)), 0) - Math.max(-args.estimate.total, 0);
    await posStore.kv.set(`seq:${s.id}`, seq + 1);
    await posStore.kv.set(`boot:${boot.location.id}`, nb);
    setBoot(nb);
    await enqueue(item);

    const paid = payments.reduce((a, p) => a + p.amount, 0);
    const cash = payments.filter((p) => p.method === "cash").reduce((a, p) => a + p.amount, 0);
    setReceipt({
      _txn: id, receipt_no: `${s.receipt_prefix}-${String(seq).padStart(4, "0")}`, invoice_no: null, created_at: now, print_count: 0,
      location: boot.shop?.name ?? boot.location.name, is_walk_in: !args.customer,
      subtotal_net: args.estimate.total, tax_total: 0, total: args.estimate.total,
      company: boot.is_dealer && boot.shop ? { name: boot.shop.name, footer: boot.company.footer } : { name: boot.company.name, vat_no: boot.company.vat_no, footer: boot.company.footer },
      customer: { name: args.customer?.name ?? "Walk-in", customer_no: args.customer?.customer_no ?? "" },
      staff: userName, lines: args.estimate.lines, payments: args.estimate.total < 0 ? [{ method: "cash", amount: args.estimate.total }] : payments,
      paid: Math.min(paid, Math.max(args.estimate.total, 0)), method: payments[0]?.method ?? null, tendered: args.tendered,
      change: args.tendered && cash ? Math.max(args.tendered - Math.min(cash, args.estimate.total), 0) : null,
      outstanding: args.customer ? Number(args.customer.outstanding) + Math.max(args.estimate.total - paid, 0) : 0,
      bottles: { issued: { x: args.estimate.issued }, returned: { x: args.estimate.returned }, external: args.estimate.extList, balance: args.customer ? args.estimate.balanceAfter : null },
      pending_sync: true,
    });
    setView("receipt");
  };

  const exit = async () => {
    if (pending.length > 0) { setError(`${pending.length} sale(s) have not reached the office yet. Stay signed in until they sync.`); return; }
    await signOut();
  };

  // ---------- render ----------
  return (
    <div className="flex min-h-dvh flex-col bg-surface">
      <header className="no-print sticky top-0 z-30 flex flex-wrap items-center justify-between gap-2 border-b border-line bg-white px-4 py-2.5">
        <div className="flex items-center gap-2.5">
          <OlaMark className="h-8 w-8" />
          <div className="leading-tight">
            <p className="text-sm font-semibold">{boot?.shop?.name ?? boot?.location.name ?? "Till"}</p>
            <p className="text-xs text-muted">{userName}{boot?.session && ` · ${boot.session.session_no}`}{boot?.is_dealer && " · dealer shop"}</p>
          </div>
        </div>
        <div className="flex items-center gap-2 text-xs">
          {!online && <span className="flex items-center gap-1 rounded-full bg-amber-100 px-2 py-1 font-medium text-amber-900"><CloudOff className="h-3.5 w-3.5" /> Offline</span>}
          {pending.length > 0 && <button onClick={sync} className="flex items-center gap-1 rounded-full bg-ola-100 px-2 py-1 font-medium text-ola-800"><RefreshCw className={`h-3.5 w-3.5 ${syncing ? "animate-spin" : ""}`} /> {pending.length} to sync</button>}
          {online && pending.length === 0 && refused.length === 0 && <span className="flex items-center gap-1 text-emerald-700"><CheckCircle2 className="h-3.5 w-3.5" /> Synced</span>}
          {locations.length > 1 && view !== "loading" && <button onClick={() => setView("choose")} className="rounded-lg border border-line px-2 py-1.5 font-medium">Switch counter</button>}
          {boot?.session && view === "sell" && <button onClick={() => setView("close")} className="rounded-lg border border-line px-2 py-1.5 font-medium">Close till</button>}
          <a href={boot?.shop ? `/shops/${boot.shop.id}` : "/"} className="rounded-lg border border-line px-2 py-1.5 font-medium">Back office</a>
          <button onClick={exit} aria-label="Sign out" className="rounded-lg p-1.5 text-muted"><LogOut className="h-4 w-4" /></button>
        </div>
      </header>

      <main className="flex-1 p-3 sm:p-4">
        {refused.length > 0 && (
          <div className="no-print mb-3 rounded-xl border border-red-200 bg-red-50 p-3 text-sm text-red-900">
            <p className="flex items-center gap-2 font-semibold"><TriangleAlert className="h-4 w-4" /> {refused.length} sale(s) were refused by the office system</p>
            {refused.map((e) => (
              <p key={e.id} className="mt-1">{e.label}: {e.error} <button onClick={() => retry(e.id)} className="ml-2 font-semibold text-ola-700">Try again</button></p>
            ))}
            <p className="mt-1 text-xs">Nothing is lost — the sale stays on this device. Tell your manager.</p>
          </div>
        )}
        {cached && view !== "choose" && <p className="no-print mb-3 rounded-lg bg-amber-50 px-3 py-2 text-xs text-amber-900">Working offline from the copy saved on this device. Sales are kept and sent when the internet returns.</p>}
        {error && <p className="no-print mb-3 rounded-lg bg-red-50 px-3 py-2 text-sm text-red-800">{error} <button className="ml-2 font-semibold" onClick={() => setError("")}>Dismiss</button></p>}

        {view === "loading" && <p className="p-8 text-center text-muted">Loading the till…</p>}

        {view === "choose" && (
          <div className="mx-auto max-w-lg space-y-3">
            <h1 className="text-xl font-semibold">Choose a counter</h1>
            {locations.length === 0 && <p className="rounded-xl bg-white p-6 text-center text-sm text-muted ring-1 ring-line">You are not set up to use any till. Ask an administrator.</p>}
            {locations.map((l) => (
              <button key={l.id} onClick={() => choose(l.id)} className="flex w-full items-center justify-between rounded-xl bg-white p-4 text-left shadow-sm ring-1 ring-line">
                <span><span className="block font-semibold">{l.name}</span><span className="text-sm text-muted">{l.type === "water_shop" ? (l.operating_model === "dealer" ? "Dealer shop" : "OLA shop") : "Head-office counter"}</span></span>
                <span className={`text-xs font-medium ${l.till_open ? "text-emerald-700" : "text-muted"}`}>{l.till_open ? "Till open" : "Till closed"}</span>
              </button>
            ))}
          </div>
        )}

        {view === "open" && boot && <OpenTill boot={boot} onOpen={openTill} online={online} />}
        {view === "sell" && boot?.session && <Sell boot={boot} online={online} onCharge={charge} />}
        {view === "receipt" && receipt && <ReceiptView r={receipt} onNext={() => { setReceipt(null); setView("sell"); }} />}
        {view === "close" && boot?.session && (
          <CloseTill boot={boot} online={online} pendingHere={pending.filter((p) => p.session_id === boot.session!.id).length} onBack={() => setView("sell")} onClose={closeTill} />
        )}
        {view === "closed" && closeResult && (
          <div className="mx-auto max-w-lg space-y-4 rounded-2xl bg-white p-5 shadow-sm ring-1 ring-line">
            <h1 className="text-xl font-semibold">Till {closeResult.session_no} closed</h1>
            <table className="w-full text-sm">
              <thead><tr className="text-left text-muted"><th className="py-1">Item</th><th className="py-1 text-right">Expected</th><th className="py-1 text-right">Counted</th></tr></thead>
              <tbody>{closeResult.lines.map((l) => (
                <tr key={l.item} className={`border-t border-line ${Number(l.expected) !== Number(l.actual) ? "font-semibold text-red-700" : ""}`}>
                  <td className="py-1.5">{l.item}</td><td className="num py-1.5 text-right">{Number(l.expected).toLocaleString("en-LK")}</td><td className="num py-1.5 text-right">{Number(l.actual).toLocaleString("en-LK")}</td>
                </tr>))}</tbody>
            </table>
            <p className="text-sm">{closeResult.exceptions === 0 ? "Everything matched." : `${closeResult.exceptions} difference(s) were reported to the office.`}</p>
            <button onClick={() => locId && loadBoot(locId)} className="h-12 w-full rounded-xl bg-ola-600 font-semibold text-white">Done</button>
          </div>
        )}
      </main>
    </div>
  );
}

// ======================================================================
function OpenTill({ boot, onOpen, online }: { boot: PosBoot; onOpen: (f: number) => Promise<void>; online: boolean }) {
  const [float, setFloat] = useState("0");
  const [busy, setBusy] = useState(false);
  return (
    <div className="mx-auto max-w-sm space-y-4 rounded-2xl bg-white p-5 shadow-sm ring-1 ring-line">
      <h1 className="text-xl font-semibold">Open the till</h1>
      <p className="text-sm text-muted">{boot.shop?.name ?? boot.location.name}. Count the cash in the drawer before the first sale.</p>
      <label className="block text-sm font-medium">Cash in the drawer (float), Rs.
        <input type="number" inputMode="decimal" min={0} value={float} onChange={(e) => setFloat(e.target.value)} className="mt-1 h-12 w-full rounded-xl border border-line px-3 text-lg" />
      </label>
      <button disabled={busy || !online} onClick={async () => { setBusy(true); await onOpen(Number(float || 0)); setBusy(false); }}
        className="h-12 w-full rounded-xl bg-ola-600 font-semibold text-white disabled:opacity-50">{online ? "Open till" : "Needs internet to open"}</button>
    </div>
  );
}

// ======================================================================
type Estimate = { lines: { description: string; qty: number; unit_price: number; discount: number; total: number }[]; total: number; issued: number;
  returned: number; balanceAfter: number; extList: { company: string; qty: number }[]; discountBlocked: boolean };

function Sell({ boot, online, onCharge }: {
  boot: PosBoot; online: boolean;
  onCharge: (a: { customer: PosCustomer | null; lines: Line[]; olaBack: number; codes: string[]; ext: Record<string, number>; payments: Pay[]; tendered: number | null; estimate: Estimate }) => Promise<void>;
}) {
  const [lines, setLines] = useState<Line[]>([]);
  const [customer, setCustomer] = useState<PosCustomer | null>(null);
  const [olaBack, setOlaBack] = useState(0);
  const [codes, setCodes] = useState<string[]>([]);
  const [ext, setExt] = useState<Record<string, number>>({});
  const [pays, setPays] = useState<Pay[]>([{ method: "cash", amount: "", reference: "" }]);
  const [tendered, setTendered] = useState("");
  const [msg, setMsg] = useState("");
  const [busy, setBusy] = useState(false);
  const [search, setSearch] = useState("");
  const [hits, setHits] = useState<PosCustomer[]>([]);
  const [picking, setPicking] = useState(false);

  const mainType = boot.bottle_types[0]?.id ?? "";
  const own = boot.own_company_id;
  const ownValue = boot.bottle_values.find((v) => v.company_id === own && v.bottle_type_id === mainType);
  const policyFor = (cid: string) => customer?.external_policy ?? boot.companies.find((c) => c.id === cid)?.policy ?? boot.settings.external_policy_default;
  const priceOf = (pid: string) => {
    const base = boot.products.find((p) => p.id === pid)?.price ?? null;
    if (customer && !boot.is_dealer && customer.prices && customer.prices[pid] !== undefined) return Number(customer.prices[pid]);
    return base === null ? null : Number(base);
  };

  const add = (pid: string, n = 1) => setLines((ls) => {
    const i = ls.findIndex((l) => l.product_id === pid);
    if (i < 0) return [...ls, { product_id: pid, qty: n, discount: 0 }];
    return ls.map((l, j) => (j === i ? { ...l, qty: Math.max(0, l.qty + n) } : l)).filter((l) => l.qty > 0);
  });

  const onScan = (code: string) => {
    const pr = boot.products.find((p) => p.barcode?.toUpperCase() === code || p.sku === code);
    if (pr) return add(pr.id);
    if (/^(OLA-BTL|EXT)-/.test(code)) {
      if (codes.includes(code)) return setMsg(`${code} already scanned`);
      const co = code.startsWith("EXT-") ? boot.companies.find((c) => c.code === code.split("-")[1]) : null;
      if (co && policyFor(co.id) === "refuse") return setMsg(`${co.name} bottles are not accepted`);
      setMsg("");
      return setCodes((c) => [code, ...c]);
    }
    setMsg(`${code} is not a product or bottle label`);
  };

  const est: Estimate = useMemo(() => {
    const out: Estimate["lines"] = [];
    let total = 0, issued = 0, blocked = false;
    for (const l of lines) {
      const pr = boot.products.find((p) => p.id === l.product_id);
      const price = priceOf(l.product_id) ?? 0;
      if (!pr || l.qty <= 0) continue;
      const t = l.qty * price - l.discount;
      if (l.discount > 0 && !boot.settings.can_discount && (l.discount / (l.qty * price || 1)) * 100 > boot.settings.discount_percent) blocked = true;
      out.push({ description: pr.name, qty: l.qty, unit_price: price, discount: l.discount, total: t });
      total += t;
      if (pr.is_returnable) issued += l.qty;
    }
    const scannedOla = codes.filter((c) => !c.startsWith("EXT-")).length;
    const extAll: Record<string, number> = { ...ext };
    codes.filter((c) => c.startsWith("EXT-")).forEach((c) => { const co = boot.companies.find((x) => x.code === c.split("-")[1]); if (co) extAll[co.id] = (extAll[co.id] ?? 0) + 1; });
    let credited = 0;
    const extList: Estimate["extList"] = [];
    for (const [cid, n] of Object.entries(extAll)) {
      if (n <= 0) continue;
      const pol = policyFor(cid);
      extList.push({ company: boot.companies.find((c) => c.id === cid)?.name ?? "", qty: n });
      if (pol === "accept_one_for_one" || pol === "accept_with_charge") credited += n;
      if (pol === "accept_with_charge") {
        const ch = Number(boot.bottle_values.find((v) => v.company_id === cid && v.bottle_type_id === mainType)?.external_charge ?? 0);
        if (ch > 0) { out.push({ description: `${extList[extList.length - 1].company} bottle charge`, qty: n, unit_price: ch, discount: 0, total: n * ch }); total += n * ch; }
      }
    }
    const returned = olaBack + scannedOla + credited;
    const before = customer ? Number(customer.ola_bottles) : Number(boot.walk_in_bottles);
    const balanceAfter = before + issued - returned;
    const model = customer ? customer.bottle_model : "deposit";
    if (!boot.is_dealer && model === "deposit" && Number(ownValue?.deposit ?? 0) > 0) {
      const held = Number((customer ? customer.deposits_held : boot.walk_in_deposits)[mainType] ?? 0);
      const delta = Math.max(balanceAfter, 0) - held;
      if (delta !== 0) {
        const dep = Number(ownValue?.deposit ?? 0);
        out.push({ description: delta > 0 ? "Bottle deposit" : "Deposit refund", qty: Math.abs(delta), unit_price: delta > 0 ? dep : -dep, discount: 0, total: delta * dep });
        total += delta * dep;
      }
    }
    return { lines: out, total: Math.round(total * 100) / 100, issued, returned, balanceAfter, extList, discountBlocked: blocked };
  }, [lines, codes, ext, olaBack, customer, boot]); // eslint-disable-line react-hooks/exhaustive-deps

  const due = Math.max(est.total, 0);
  const entered = pays.reduce((a, p) => a + (p.amount === "" ? 0 : Number(p.amount)), 0);
  const firstAuto = pays.length === 1 && pays[0].amount === "";
  const paidTotal = firstAuto ? due : entered;
  const cashPaid = pays.filter((p) => p.method === "cash").reduce((a, p, i) => a + (firstAuto && i === 0 ? due : Number(p.amount || 0)), 0);
  const change = tendered !== "" ? Math.max(Number(tendered) - Math.min(cashPaid, due), 0) : 0;
  const short = Math.max(due - paidTotal, 0);
  const allowCredit = customer && customer.credit_limit > 0;
  const nothing = est.lines.length === 0 && est.returned === 0 && codes.length === 0;

  const reset = () => { setLines([]); setCustomer(null); setOlaBack(0); setCodes([]); setExt({}); setPays([{ method: "cash", amount: "", reference: "" }]); setTendered(""); setMsg(""); };

  const submit = async () => {
    setMsg("");
    if (nothing) return setMsg("Add a product or a returned bottle first.");
    if (est.discountBlocked) return setMsg(`Discounts above ${boot.settings.discount_percent}% need a manager.`);
    if (lines.some((l) => priceOf(l.product_id) === null)) return setMsg("A product has no price at this counter. Ask the office to set it.");
    if (short > 0.009 && !allowCredit) return setMsg(customer ? `${customer.name} has no credit — collect the full amount.` : "Walk-in customers must pay the full amount.");
    if (pays.some((p) => ["bank_transfer", "cheque"].includes(p.method) && Number(p.amount || (firstAuto ? due : 0)) > 0 && !p.reference.trim())) return setMsg("Enter the bank or cheque reference.");
    if (tendered !== "" && Number(tendered) < Math.min(cashPaid, due)) return setMsg("Cash tendered is less than the cash amount.");
    setBusy(true);
    const payments = firstAuto ? (due > 0 ? [{ ...pays[0], amount: String(due) }] : []) : pays;
    await onCharge({ customer, lines, olaBack, codes, ext, payments, tendered: tendered === "" ? null : Number(tendered), estimate: est });
    reset();
    setBusy(false);
  };

  const findCustomers = async (q: string) => {
    setSearch(q);
    if (q.trim().length < 2) return setHits([]);
    const r = await rpc<PosCustomer[]>("pos_find_customer", { p_location: boot.location.id, p_search: q });
    setHits(r.data ?? []);
    if (r.offline) setMsg("Customer search needs internet — sell as walk-in for now.");
  };

  return (
    <div className="grid gap-4 lg:grid-cols-[1fr_420px]">
      {/* products */}
      <section className="space-y-3">
        <div className="no-print"><Scanner onScan={onScan} label="Scan with camera" /></div>
        <div className="grid grid-cols-2 gap-3 sm:grid-cols-3 xl:grid-cols-4">
          {boot.products.map((p) => {
            const price = priceOf(p.id);
            const inCart = lines.find((l) => l.product_id === p.id)?.qty ?? 0;
            return (
              <button key={p.id} onClick={() => price !== null && add(p.id)} disabled={price === null}
                className={`relative rounded-2xl bg-white p-4 text-left shadow-sm ring-1 disabled:opacity-40 ${inCart ? "ring-2 ring-ola-600" : "ring-line"}`}>
                {inCart > 0 && <span className="absolute right-2 top-2 flex h-7 min-w-7 items-center justify-center rounded-full bg-ola-600 px-2 text-sm font-bold text-white">{inCart}</span>}
                <span className="block text-base font-semibold leading-tight">{p.name}</span>
                <span className="mt-2 block text-lg font-semibold text-ola-700">{price === null ? "No price" : rs(price)}</span>
                <span className={`block text-xs ${p.stock <= 0 ? "text-red-700" : "text-muted"}`}>{p.stock} in stock</span>
              </button>
            );
          })}
        </div>
      </section>

      {/* cart */}
      <section className="space-y-3">
        <div className="rounded-2xl bg-white p-4 shadow-sm ring-1 ring-line">
          <div className="flex items-center justify-between gap-2">
            <span className="flex items-center gap-2 font-semibold"><UserRound className="h-4 w-4" /> {customer ? customer.name : "Walk-in customer"}</span>
            {customer ? <button onClick={() => setCustomer(null)} className="text-sm font-medium text-ola-700">Walk-in</button>
              : <button onClick={() => setPicking((v) => !v)} className="text-sm font-medium text-ola-700">{picking ? "Cancel" : "Registered customer"}</button>}
          </div>
          {customer && <p className="mt-1 text-xs text-muted">{customer.customer_no} · holds {customer.ola_bottles} bottle(s) · owes {rs(customer.outstanding)}{customer.credit_limit > 0 ? ` · limit ${rs(customer.credit_limit)}` : " · no credit"}</p>}
          {picking && !customer && (
            <div className="mt-2">
              <div className="relative"><Search className="pointer-events-none absolute left-3 top-3 h-4 w-4 text-muted" />
                <input value={search} onChange={(e) => findCustomers(e.target.value)} placeholder={online ? "Name, number or phone" : "Needs internet"} disabled={!online}
                  className="h-10 w-full rounded-xl border border-line pl-9 pr-3 text-sm" /></div>
              {hits.map((h) => (
                <button key={h.id} onClick={() => { setCustomer(h); setPicking(false); setHits([]); setSearch(""); }} className="mt-1 block w-full rounded-lg px-3 py-2 text-left text-sm hover:bg-ola-50">
                  {h.name} <span className="text-muted">{h.customer_no}</span>{h.status === "on_hold" && <span className="ml-1 text-red-700">on hold</span>}
                </button>
              ))}
            </div>
          )}
        </div>

        <div className="rounded-2xl bg-white p-4 shadow-sm ring-1 ring-line">
          {lines.length === 0 && <p className="text-sm text-muted">Tap a product or scan its barcode.</p>}
          <ul className="space-y-2">
            {lines.map((l) => {
              const pr = boot.products.find((p) => p.id === l.product_id)!;
              const price = priceOf(l.product_id) ?? 0;
              return (
                <li key={l.product_id} className="flex items-center gap-2">
                  <span className="min-w-0 flex-1"><span className="block truncate text-sm font-medium">{pr.name}</span>
                    <span className="text-xs text-muted">{rs(price)} each{l.discount > 0 && ` · less ${rs(l.discount)}`}</span></span>
                  <button onClick={() => add(l.product_id, -1)} className="flex h-10 w-10 items-center justify-center rounded-xl border border-line" aria-label="Fewer"><Minus className="h-4 w-4" /></button>
                  <span className="num w-8 text-center font-semibold">{l.qty}</span>
                  <button onClick={() => add(l.product_id, 1)} className="flex h-10 w-10 items-center justify-center rounded-xl border border-line" aria-label="More"><Plus className="h-4 w-4" /></button>
                  <input type="number" min={0} value={l.discount || ""} placeholder="Disc." aria-label={`Discount on ${pr.name}`}
                    onChange={(e) => setLines((ls) => ls.map((x) => (x.product_id === l.product_id ? { ...x, discount: Math.max(0, Number(e.target.value) || 0) } : x)))}
                    className="h-10 w-20 rounded-xl border border-line px-2 text-sm" />
                </li>
              );
            })}
          </ul>
        </div>

        <div className="space-y-2 rounded-2xl bg-white p-4 shadow-sm ring-1 ring-line">
          <p className="text-sm font-semibold">Empty bottles brought back</p>
          <Counter label="OLA bottles" value={olaBack} onChange={setOlaBack} />
          {boot.companies.filter((c) => !c.is_own && policyFor(c.id) !== "refuse").map((c) => (
            <Counter key={c.id} label={c.name} hint={policyFor(c.id) === "accept_one_for_one" ? "counts as returned" : policyFor(c.id) === "accept_with_charge" ? "charged" : "no credit"}
              value={ext[c.id] ?? 0} onChange={(v) => setExt((e) => ({ ...e, [c.id]: v }))} />
          ))}
          {codes.length > 0 && (
            <ul className="flex flex-wrap gap-1">{codes.map((c) => (
              <li key={c} className="flex items-center gap-1 rounded-lg bg-surface px-2 py-1 font-mono text-xs">{c}<button onClick={() => setCodes((x) => x.filter((y) => y !== c))} aria-label={`Remove ${c}`}><X className="h-3 w-3" /></button></li>
            ))}</ul>
          )}
        </div>

        <div className="space-y-3 rounded-2xl bg-white p-4 shadow-sm ring-1 ring-line">
          <div className="space-y-1 text-sm">
            {est.lines.map((l, i) => <div key={i} className="flex justify-between"><span>{l.qty} × {l.description}</span><span className="num">{rs(l.total)}</span></div>)}
            <div className="flex justify-between border-t border-line pt-2 text-lg font-semibold"><span>{est.total < 0 ? "Pay back" : "Total"}</span><span className="num">{rs(Math.abs(est.total))}</span></div>
            {!boot.is_dealer && <p className="text-xs text-muted">{customer ? `Bottles after this sale: ${est.balanceAfter}` : "Deposits apply when bottles leave without empties coming back"}</p>}
          </div>
          {est.total > 0 && (
            <>
              {pays.map((p, i) => (
                <div key={i} className="space-y-2 rounded-xl bg-surface p-2">
                  <div className="grid grid-cols-5 gap-1">
                    {METHODS.map(([v, l]) => (
                      <button key={v} onClick={() => setPays((ps) => ps.map((x, j) => (j === i ? { ...x, method: v } : x)))}
                        className={`h-9 rounded-lg text-xs font-medium ${p.method === v ? "bg-ola-600 text-white" : "bg-white ring-1 ring-line"}`}>{l}</button>
                    ))}
                  </div>
                  <div className="flex gap-2">
                    <input type="number" inputMode="decimal" placeholder={pays.length === 1 ? `Full amount (${due.toLocaleString("en-LK")})` : "Amount"} value={p.amount}
                      onChange={(e) => setPays((ps) => ps.map((x, j) => (j === i ? { ...x, amount: e.target.value } : x)))} className="h-10 flex-1 rounded-lg border border-line px-2 text-sm" />
                    {["bank_transfer", "cheque", "card", "qr"].includes(p.method) && (
                      <input placeholder="Reference" value={p.reference} onChange={(e) => setPays((ps) => ps.map((x, j) => (j === i ? { ...x, reference: e.target.value } : x)))}
                        className="h-10 w-28 rounded-lg border border-line px-2 text-sm" />
                    )}
                    {pays.length > 1 && <button onClick={() => setPays((ps) => ps.filter((_, j) => j !== i))} aria-label="Remove payment" className="px-1 text-muted"><X className="h-4 w-4" /></button>}
                  </div>
                </div>
              ))}
              <div className="flex items-center justify-between text-sm">
                <button onClick={() => setPays((ps) => [...ps.map((x) => ({ ...x, amount: x.amount === "" ? String(due) : x.amount })), { method: "card", amount: "", reference: "" }])}
                  className="font-medium text-ola-700">+ Split payment</button>
                {short > 0.009 && <span className={allowCredit ? "text-amber-700" : "text-red-700"}>{rs(short)} {allowCredit ? "on account" : "still to pay"}</span>}
              </div>
              {cashPaid > 0 && (
                <label className="flex items-center justify-between gap-2 text-sm font-medium">Cash tendered
                  <input type="number" inputMode="decimal" value={tendered} onChange={(e) => setTendered(e.target.value)} className="h-10 w-36 rounded-lg border border-line px-2 text-right text-base" />
                </label>
              )}
              {change > 0 && <p className="text-right text-lg font-semibold text-emerald-700">Change {rs(change)}</p>}
            </>
          )}
          {msg && <p className="rounded-lg bg-amber-50 px-3 py-2 text-sm text-amber-900">{msg}</p>}
          <div className="grid grid-cols-3 gap-2">
            <button onClick={reset} className="h-14 rounded-2xl border border-line font-semibold">Clear</button>
            <button disabled={busy || nothing} onClick={submit} className="col-span-2 h-14 rounded-2xl bg-ola-600 text-lg font-semibold text-white disabled:opacity-50">
              {est.total < 0 ? `Refund ${rs(-est.total)}` : `Charge ${rs(due)}`}
            </button>
          </div>
        </div>
      </section>
    </div>
  );
}

function Counter({ label, hint, value, onChange }: { label: string; hint?: string; value: number; onChange: (v: number) => void }) {
  return (
    <div className="flex items-center justify-between gap-2">
      <span className="text-sm">{label}{hint && <span className="block text-xs text-muted">{hint}</span>}</span>
      <span className="flex items-center gap-2">
        <button onClick={() => onChange(Math.max(0, value - 1))} className="flex h-10 w-10 items-center justify-center rounded-xl border border-line" aria-label={`Fewer ${label}`}><Minus className="h-4 w-4" /></button>
        <span className="num w-6 text-center font-semibold">{value}</span>
        <button onClick={() => onChange(value + 1)} className="flex h-10 w-10 items-center justify-center rounded-xl border border-line" aria-label={`More ${label}`}><Plus className="h-4 w-4" /></button>
      </span>
    </div>
  );
}

// ======================================================================
function ReceiptView({ r, onNext }: { r: ReceiptData & { _txn?: string; sale_id?: string }; onNext: () => void }) {
  const [msg, setMsg] = useState("");
  const [printed, setPrinted] = useState(r.print_count ?? 0);
  const print = async () => {
    setMsg("");
    if (r.sale_id && navigator.onLine) {
      const res = await rpc<number>("record_pos_receipt_print", { p_sale: r.sale_id, p_reason: printed > 0 ? "Reprint at the counter" : null });
      if (res.error && !res.offline) return setMsg(res.error);
      if (res.data) setPrinted(res.data);
    }
    setTimeout(() => window.print(), 50);
  };
  return (
    <div className="mx-auto max-w-md space-y-3">
      <Receipt80 r={{ ...r, print_count: printed > 1 ? 1 : 0 }} />
      <div className="no-print grid grid-cols-2 gap-2">
        <button onClick={print} className="flex h-14 items-center justify-center gap-2 rounded-2xl bg-navy-900 font-semibold text-white"><Printer className="h-5 w-5" /> Print</button>
        <button onClick={onNext} className="h-14 rounded-2xl bg-ola-600 font-semibold text-white">Next customer</button>
      </div>
      {msg && <p className="no-print text-sm text-red-700">{msg}</p>}
      {r.pending_sync && <p className="no-print text-center text-xs text-muted">Saved on this device; it is sent to the office automatically.</p>}
    </div>
  );
}

// ======================================================================
function CloseTill({ boot, online, pendingHere, onBack, onClose }: { boot: PosBoot; online: boolean; pendingHere: number; onBack: () => void;
  onClose: (p: Record<string, unknown>) => Promise<void> }) {
  const [cash, setCash] = useState("");
  const [card, setCard] = useState("");
  const [count, setCount] = useState(true);
  const [prod, setProd] = useState<Record<string, string>>({});
  const [bot, setBot] = useState<Record<string, string>>({});
  const [notes, setNotes] = useState("");
  const [busy, setBusy] = useState(false);
  const mainType = boot.bottle_types[0]?.id ?? "";
  const counted = boot.products.filter((p) => p.stock !== 0 || prod[p.id] !== undefined);
  const missing = count && (counted.some((p) => (prod[p.id] ?? "") === "") || boot.companies.some((c) => (bot[c.id] ?? "") === ""));
  const blocked = !online || pendingHere > 0 || cash === "" || missing;

  return (
    <div className="mx-auto max-w-2xl space-y-4 rounded-2xl bg-white p-5 shadow-sm ring-1 ring-line">
      <div className="flex items-center justify-between"><h1 className="text-xl font-semibold">Close the till</h1><button onClick={onBack} className="text-sm font-medium text-ola-700">Back to selling</button></div>
      <p className="text-sm text-muted">Count everything without looking at the system figures. Differences are reported to the office automatically.</p>
      {pendingHere > 0 && <p className="rounded-lg bg-amber-50 px-3 py-2 text-sm text-amber-900">{pendingHere} sale(s) are still waiting to reach the office. Connect to the internet and wait for them to sync.</p>}
      <div className="grid gap-3 sm:grid-cols-2">
        <label className="text-sm font-medium">Cash in the drawer (incl. float), Rs.
          <input type="number" inputMode="decimal" value={cash} onChange={(e) => setCash(e.target.value)} className="mt-1 h-12 w-full rounded-xl border border-line px-3 text-lg" /></label>
        <label className="text-sm font-medium">Card / QR terminal total, Rs.
          <input type="number" inputMode="decimal" value={card} onChange={(e) => setCard(e.target.value)} className="mt-1 h-12 w-full rounded-xl border border-line px-3 text-lg" /></label>
      </div>
      <label className="flex items-center gap-2 text-sm"><input type="checkbox" checked={count} onChange={(e) => setCount(e.target.checked)} /> Count stock and bottles too (recommended daily)</label>
      {count && (
        <div className="grid gap-3 sm:grid-cols-2">
          {counted.map((p) => (
            <label key={p.id} className="text-sm">{p.name} (full)
              <input type="number" min={0} value={prod[p.id] ?? ""} onChange={(e) => setProd((v) => ({ ...v, [p.id]: e.target.value }))} className="mt-1 h-11 w-full rounded-xl border border-line px-3" /></label>
          ))}
          {boot.companies.map((c) => (
            <label key={c.id} className="text-sm">{c.name} empties
              <input type="number" min={0} value={bot[c.id] ?? ""} onChange={(e) => setBot((v) => ({ ...v, [c.id]: e.target.value }))} className="mt-1 h-11 w-full rounded-xl border border-line px-3" /></label>
          ))}
        </div>
      )}
      <label className="block text-sm">Notes<input value={notes} onChange={(e) => setNotes(e.target.value)} className="mt-1 h-11 w-full rounded-xl border border-line px-3" /></label>
      <button disabled={blocked || busy} onClick={async () => {
        setBusy(true);
        await onClose({
          cash_counted: Number(cash), card_counted: card === "" ? null : Number(card), notes,
          products: count ? counted.map((p) => ({ product_id: p.id, qty: Number(prod[p.id] || 0) })) : [],
          bottles: count ? boot.companies.map((c) => ({ company_id: c.id, bottle_type_id: mainType, fill_state: "empty", qty: Number(bot[c.id] || 0) })) : [],
        });
        setBusy(false);
      }} className="h-14 w-full rounded-2xl bg-navy-900 text-lg font-semibold text-white disabled:opacity-50">
        {!online ? "Needs internet to close" : missing ? "Enter every count (0 if none)" : "Close till"}
      </button>
    </div>
  );
}
