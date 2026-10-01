"use client";

import { useCallback, useEffect, useState } from "react";
import { ArrowLeft, CheckCircle2, ChevronRight, CloudOff, LogOut, Printer, RefreshCw, TriangleAlert, Truck, XCircle } from "lucide-react";
import { browserClient } from "@/lib/supabase/browser";
import { Receipt80 } from "@/components/receipt";
import { OlaMark } from "@/components/layout/logo";
import { kv } from "./store";
import { loadRun, loadRuns, saveRunLocal, useDriverSync } from "./sync";
import { StopView } from "./stop-view";
import type { LocalReceipt, RunData, RunSummary } from "./types";

type View = { screen: "runs" } | { screen: "run"; runId: string } | { screen: "stop"; runId: string; deliveryId: string } | { screen: "receipt"; runId: string; deliveryId: string };

const rs = (n: number) => `Rs. ${Number(n).toLocaleString("en-LK", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;

export function DriverApp({ userName, signOut }: { userName: string; signOut: () => Promise<void> }) {
  const { online, items, syncing, sync, enqueue, retry } = useDriverSync();
  const [view, setView] = useState<View>({ screen: "runs" });
  const [runs, setRuns] = useState<RunSummary[]>([]);
  const [run, setRun] = useState<RunData | null>(null);
  const [offlineData, setOfflineData] = useState(false);
  const [error, setError] = useState("");
  const [receipt, setReceipt] = useState<LocalReceipt | null>(null);

  const refreshRuns = useCallback(async () => {
    const r = await loadRuns();
    setRuns(r.runs);
    setOfflineData(r.offline);
  }, []);

  const openRun = useCallback(async (runId: string) => {
    const r = await loadRun(runId);
    setRun(r.run);
    setOfflineData(r.offline);
    setError(r.error ?? (r.run ? "" : "This run is not saved on the phone yet. Connect to the internet once to download it."));
  }, []);

  useEffect(() => { refreshRuns(); }, [refreshRuns]);
  useEffect(() => { if (view.screen !== "runs") openRun(view.runId); }, [view, openRun]);
  // after a sync finishes, refresh what is on screen
  useEffect(() => {
    if (syncing) return;
    if (view.screen === "runs") refreshRuns();
    else if (view.screen === "run") openRun(view.runId);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [syncing]);

  const startRun = async () => {
    if (!run) return;
    const id = crypto.randomUUID();
    const updated = { ...run, run: { ...run.run, status: "in_progress" } };
    setRun(updated);
    await saveRunLocal(updated);
    await enqueue({ id, fn: "driver_start_run", args: { p_run: run.run.id }, run_id: run.run.id, label: `Start ${run.run.run_no}`, created_at: new Date().toISOString(), status: "pending", attempts: 0 });
  };

  const errors = items.filter((i) => i.status === "error");
  const pending = items.filter((i) => i.status === "pending");

  return (
    <div className="mx-auto min-h-dvh max-w-xl bg-surface">
      <header className="no-print sticky top-0 z-30 flex items-center justify-between border-b border-line bg-white px-4 py-3">
        <div className="flex items-center gap-2"><OlaMark className="h-8 w-8" /><div className="leading-tight"><p className="text-sm font-semibold">OLA Driver</p><p className="text-xs text-muted">{userName}</p></div></div>
        <div className="flex items-center gap-2">
          {!online && <span className="flex items-center gap-1 rounded-full bg-amber-100 px-2 py-1 text-xs font-medium text-amber-900"><CloudOff className="h-3.5 w-3.5" /> Offline</span>}
          {pending.length > 0 && <button onClick={sync} className="flex items-center gap-1 rounded-full bg-ola-100 px-2 py-1 text-xs font-medium text-ola-800"><RefreshCw className={`h-3.5 w-3.5 ${syncing ? "animate-spin" : ""}`} /> {pending.length} to sync</button>}
          {online && pending.length === 0 && errors.length === 0 && <span className="flex items-center gap-1 text-xs text-emerald-700"><CheckCircle2 className="h-3.5 w-3.5" /> Synced</span>}
          <button onClick={() => signOut()} aria-label="Sign out" className="rounded-lg p-2 text-muted"><LogOut className="h-4 w-4" /></button>
        </div>
      </header>

      <main className="p-4">
        {errors.length > 0 && (
          <div className="no-print mb-4 rounded-2xl border border-red-200 bg-red-50 p-3 text-sm text-red-900">
            <p className="flex items-center gap-2 font-semibold"><TriangleAlert className="h-4 w-4" /> {errors.length} item(s) were refused by the office system</p>
            <ul className="mt-2 space-y-2">
              {errors.map((e) => (
                <li key={e.id} className="rounded-lg bg-white p-2">
                  <p className="font-medium">{e.label}</p><p className="text-xs">{e.error}</p>
                  <button onClick={() => retry(e.id)} className="mt-1 text-xs font-semibold text-ola-700">Try again</button>
                </li>
              ))}
            </ul>
            <p className="mt-2 text-xs">Nothing is lost — call the office. They can see this on the Exceptions and Dispatch screens.</p>
          </div>
        )}
        {offlineData && <p className="no-print mb-3 rounded-lg bg-amber-50 px-3 py-2 text-xs text-amber-900">Showing the copy saved on this phone. It updates when you are back online.</p>}

        {view.screen === "runs" && (
          <div className="space-y-3">
            <h1 className="text-xl font-semibold">My runs</h1>
            {runs.length === 0 && <p className="rounded-2xl bg-white p-6 text-center text-sm text-muted ring-1 ring-line">No runs assigned to you right now.</p>}
            {runs.map((r) => (
              <button key={r.id} onClick={() => setView({ screen: "run", runId: r.id })} className="flex w-full items-center justify-between rounded-2xl bg-white p-4 text-left shadow-sm ring-1 ring-line">
                <span>
                  <span className="block text-lg font-semibold">{r.run_no}</span>
                  <span className="block text-sm text-muted">{r.route ?? "No route"} · {r.vehicle}</span>
                  <span className="mt-1 block text-sm">{r.done} of {r.stops} stops done · <span className="capitalize">{r.status.replace("_", " ")}</span></span>
                </span>
                <ChevronRight className="h-5 w-5 text-muted" />
              </button>
            ))}
          </div>
        )}

        {view.screen !== "runs" && error && !run && <p className="rounded-2xl bg-white p-6 text-sm text-muted ring-1 ring-line">{error}</p>}

        {view.screen === "run" && run && (
          <div className="space-y-4">
            <button onClick={() => setView({ screen: "runs" })} className="flex items-center gap-1 text-sm font-medium text-ola-700"><ArrowLeft className="h-4 w-4" /> My runs</button>
            <section className="rounded-2xl bg-white p-4 shadow-sm ring-1 ring-line">
              <p className="text-xs font-semibold uppercase tracking-wide text-muted">{run.run.route ?? "Run"} · {run.run.vehicle}</p>
              <h1 className="text-xl font-semibold">{run.run.run_no}</h1>
              <div className="mt-3 grid grid-cols-2 gap-2 text-sm">
                <div className="rounded-lg bg-surface p-2"><p className="text-xs text-muted">Cash with you</p><p className="num font-semibold">{rs(Number(run.run.cash_float) + Number(run.cash_collected))}</p></div>
                <div className="rounded-lg bg-surface p-2"><p className="text-xs text-muted">Stops done</p><p className="num font-semibold">{run.stops.filter((s) => s.status !== "pending").length} / {run.stops.length}</p></div>
              </div>
              <details className="mt-3 text-sm">
                <summary className="cursor-pointer font-medium text-ola-700">On the vehicle</summary>
                <ul className="mt-2 space-y-1">
                  {run.vehicle_stock.filter((v) => Number(v.qty) > 0).map((v) => <li key={v.product_id} className="flex justify-between"><span>{run.products.find((p) => p.id === v.product_id)?.name}</span><span className="num">{Number(v.qty)}</span></li>)}
                </ul>
              </details>
            </section>

            {run.run.status === "planned" && <p className="rounded-2xl bg-white p-4 text-sm ring-1 ring-line">The warehouse has not loaded your vehicle yet.</p>}
            {run.run.status === "loaded" && (
              <section className="rounded-2xl bg-white p-4 shadow-sm ring-1 ring-line">
                <p className="mb-3 text-sm">Check the load above. Tap below to confirm it is correct and start delivering.</p>
                <button onClick={startRun} className="h-14 w-full rounded-2xl bg-ola-600 text-lg font-semibold text-white"><Truck className="mr-2 inline h-5 w-5" />Confirm load & start</button>
              </section>
            )}

            {["in_progress", "checked_in", "closed"].includes(run.run.status) && (
              <ul className="space-y-2">
                {run.stops.map((s) => {
                  const done = s.status !== "pending";
                  return (
                    <li key={s.delivery_id}>
                      <button
                        onClick={() => (done ? setView({ screen: "receipt", runId: run.run.id, deliveryId: s.delivery_id }) : setView({ screen: "stop", runId: run.run.id, deliveryId: s.delivery_id }))}
                        disabled={run.run.status !== "in_progress" && !done}
                        className={`flex w-full items-center gap-3 rounded-2xl p-4 text-left ring-1 ${done ? "bg-white/60 ring-line" : "bg-white shadow-sm ring-line"}`}>
                        <span className={`flex h-9 w-9 shrink-0 items-center justify-center rounded-full text-sm font-bold ${s.status === "failed" ? "bg-red-100 text-red-700" : done ? "bg-emerald-100 text-emerald-700" : "bg-ola-100 text-ola-800"}`}>
                          {s.status === "failed" ? <XCircle className="h-5 w-5" /> : done ? <CheckCircle2 className="h-5 w-5" /> : s.stop_sequence}
                        </span>
                        <span className="min-w-0 flex-1">
                          <span className="block truncate font-semibold">{s.customer.name}</span>
                          <span className="block truncate text-sm text-muted">{s.address?.address_line ?? ""}</span>
                          <span className="block text-xs text-muted">
                            {s.order.items.map((i) => `${Number(i.qty)} × ${run.products.find((p) => p.id === i.product_id)?.name ?? ""}`).join(", ")}
                            {s.local?.pending && " · waiting to sync"}{s.status === "failed" && ` · ${s.failure_reason ?? s.local?.failed_reason ?? "not delivered"}`}
                          </span>
                        </span>
                        <ChevronRight className="h-5 w-5 shrink-0 text-muted" />
                      </button>
                    </li>
                  );
                })}
              </ul>
            )}
            {run.run.status === "in_progress" && run.stops.every((s) => s.status !== "pending") && (
              <p className="rounded-2xl bg-emerald-50 p-4 text-sm text-emerald-900">All stops done. Return to the warehouse for check-in and hand in the cash: <strong>{rs(Number(run.run.cash_float) + Number(run.cash_collected))}</strong>.</p>
            )}
          </div>
        )}

        {view.screen === "stop" && run && (() => {
          const stop = run.stops.find((s) => s.delivery_id === view.deliveryId);
          if (!stop) return null;
          return (
            <StopView run={run} stop={stop} onBack={() => setView({ screen: "run", runId: run.run.id })}
              onComplete={async (item, rec, _status, updated) => {
                setRun(updated);
                await saveRunLocal(updated);
                await enqueue(item);
                setReceipt(rec);
                setView(rec ? { screen: "receipt", runId: run.run.id, deliveryId: stop.delivery_id } : { screen: "run", runId: run.run.id });
              }} />
          );
        })()}

        {view.screen === "receipt" && run && (
          <ReceiptScreen run={run} deliveryId={view.deliveryId} fallback={receipt} onBack={() => { setReceipt(null); setView({ screen: "run", runId: run.run.id }); }} />
        )}
      </main>
    </div>
  );
}

function ReceiptScreen({ run, deliveryId, fallback, onBack }: { run: RunData; deliveryId: string; fallback: LocalReceipt | null; onBack: () => void }) {
  const stop = run.stops.find((s) => s.delivery_id === deliveryId);
  const [r, setR] = useState<LocalReceipt | null>(fallback ?? stop?.local?.receipt ?? null);
  const [msg, setMsg] = useState("");

  useEffect(() => {
    (async () => {
      const synced = await kv.get<Record<string, unknown>>(`receipt:${deliveryId}`);
      const summary = (synced ?? stop?.summary) as Record<string, unknown> | null;
      if (summary && summary.invoice_no !== undefined) {
        setR({
          ...(summary as unknown as LocalReceipt), created_at: new Date().toISOString(), print_count: 0,
          company: { name: run.company.name, vat_no: run.company.vat_no, footer: run.company.receipt_footer },
        });
      }
    })();
  }, [deliveryId, run, stop]);

  const print = async () => {
    setMsg("");
    const invoiceId = (stop?.invoice_id ?? (r as unknown as { invoice_id?: string })?.invoice_id) as string | undefined;
    if (invoiceId && navigator.onLine) {
      const { data, error } = await browserClient().rpc("record_receipt_print", { p_invoice: invoiceId, p_reason: (r?.print_count ?? 0) > 0 ? "Reprint from driver app" : null });
      if (error && !/reason/i.test(error.message)) return setMsg(error.message);
      if (error) {
        await browserClient().rpc("record_receipt_print", { p_invoice: invoiceId, p_reason: "Reprint from driver app" });
        setR((x) => (x ? { ...x, print_count: 1 } : x));
      } else if (typeof data === "number" && data > 1) setR((x) => (x ? { ...x, print_count: data - 1 } : x));
    }
    setTimeout(() => window.print(), 100);
  };

  return (
    <div className="space-y-4">
      <div className="no-print flex items-center justify-between">
        <button onClick={onBack} className="flex items-center gap-1 text-sm font-medium text-ola-700"><ArrowLeft className="h-4 w-4" /> Stops</button>
        {stop?.status === "failed" && <span className="text-sm text-red-700">Not delivered</span>}
      </div>
      {r ? (
        <>
          <Receipt80 r={{ ...r, outstanding: r.outstanding, lines: r.lines }} />
          <div className="no-print grid grid-cols-2 gap-2">
            <button onClick={print} className="flex h-14 items-center justify-center gap-2 rounded-2xl bg-navy-900 font-semibold text-white"><Printer className="h-5 w-5" /> Print</button>
            <button onClick={onBack} className="h-14 rounded-2xl bg-ola-600 font-semibold text-white">Next stop</button>
          </div>
          {msg && <p className="no-print text-sm text-red-700">{msg}</p>}
          <p className="no-print text-center text-xs text-muted">Pair a Bluetooth 80 mm printer with the phone&apos;s print service to print directly.</p>
        </>
      ) : (
        <p className="rounded-2xl bg-white p-4 text-sm ring-1 ring-line">{stop?.status === "failed" ? `Recorded as not delivered: ${stop.failure_reason ?? stop.local?.failed_reason ?? ""}` : "No receipt for this stop."}</p>
      )}
    </div>
  );
}
