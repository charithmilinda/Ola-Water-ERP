"use client";

import { useEffect, useMemo, useState, useTransition } from "react";
import { Search } from "lucide-react";
import { ActionForm } from "@/components/ui/action-form";
import { Field, Input, Select } from "@/components/ui/field";
import { Button } from "@/components/ui/button";
import { SubmitButton } from "@/components/ui/submit-button";
import { customerPricing, searchCustomers, type CustomerHit, type Pricing } from "../orders/actions";
import { saveRecurring } from "./actions";

const DAYS = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];

export function RecurringEditor({ tomorrow }: { tomorrow: string }) {
  const [q, setQ] = useState("");
  const [hits, setHits] = useState<CustomerHit[]>([]);
  const [, start] = useTransition();
  const [pricing, setPricing] = useState<Pricing | null>(null);
  const [frequency, setFrequency] = useState("weekly");
  const [weekdays, setWeekdays] = useState<number[]>([1]);
  const [interval, setInterval] = useState("3");
  const [dom, setDom] = useState("1");
  const [startDate, setStartDate] = useState(tomorrow);
  const [qty, setQty] = useState<Record<string, string>>({});
  const [returns, setReturns] = useState("");

  useEffect(() => {
    if (q.trim().length < 2) return setHits([]);
    const t = setTimeout(() => start(async () => setHits(await searchCustomers(q.trim()))), 250);
    return () => clearTimeout(t);
  }, [q]);

  const json = useMemo(() => JSON.stringify({
    customer_id: pricing?.customer.id, address_id: pricing?.addresses.find((a) => a.is_default)?.id, frequency,
    weekdays: frequency === "weekly" ? weekdays : [], interval_days: frequency === "every_n_days" ? interval : null,
    day_of_month: frequency === "monthly" ? dom : null, start_date: startDate, expected_ola_returns: returns,
    items: Object.entries(qty).filter(([, v]) => Number(v) > 0).map(([product_id, v]) => ({ product_id, qty: v })),
  }), [pricing, frequency, weekdays, interval, dom, startDate, qty, returns]);

  return (
    <ActionForm action={saveRecurring} onSuccess={() => { setPricing(null); setQty({}); }}>
      <input type="hidden" name="payload" value={json} />
      {!pricing ? (
        <Field label="Customer" htmlFor="r-cust" required>
          <div className="relative">
            <Search className="pointer-events-none absolute left-3 top-3 h-4 w-4 text-muted" />
            <Input id="r-cust" value={q} onChange={(e) => setQ(e.target.value)} className="pl-9" placeholder="Search customers" autoComplete="off" />
          </div>
          {hits.length > 0 && (
            <ul className="mt-1 max-h-56 overflow-auto rounded-lg border border-line bg-white shadow-sm">
              {hits.map((h) => (
                <li key={h.id}><button type="button" className="w-full px-3 py-2 text-left text-sm hover:bg-ola-50"
                  onClick={async () => { setHits([]); setQ(""); setPricing(await customerPricing(h.id)); }}>{h.name} <span className="text-muted">{h.customer_no}</span></button></li>
              ))}
            </ul>
          )}
        </Field>
      ) : (
        <div className="flex items-center justify-between rounded-lg border border-line bg-surface px-3 py-2 text-sm">
          <span className="font-medium">{pricing.customer.name}</span>
          <Button type="button" size="sm" variant="ghost" onClick={() => setPricing(null)}>Change</Button>
        </div>
      )}
      {pricing && (
        <>
          <div className="grid gap-4 sm:grid-cols-2">
            <Field label="How often" htmlFor="r-freq">
              <Select id="r-freq" value={frequency} onChange={(e) => setFrequency(e.target.value)}>
                <option value="daily">Every day</option>
                <option value="alternate_days">Every other day</option>
                <option value="weekly">Weekly, on chosen days</option>
                <option value="every_n_days">Every few days</option>
                <option value="monthly">Monthly</option>
              </Select>
            </Field>
            <Field label="First delivery" htmlFor="r-start"><Input id="r-start" type="date" min={tomorrow} value={startDate} onChange={(e) => setStartDate(e.target.value)} /></Field>
          </div>
          {frequency === "weekly" && (
            <div className="flex flex-wrap gap-2">
              {DAYS.map((d, i) => (
                <label key={d} className={`cursor-pointer rounded-lg border px-3 py-2 text-sm ${weekdays.includes(i + 1) ? "border-ola-600 bg-ola-50 text-ola-800" : "border-line"}`}>
                  <input type="checkbox" className="sr-only" checked={weekdays.includes(i + 1)} onChange={(e) => setWeekdays((w) => (e.target.checked ? [...w, i + 1] : w.filter((x) => x !== i + 1)))} />
                  {d}
                </label>
              ))}
            </div>
          )}
          {frequency === "every_n_days" && <Field label="Every how many days" htmlFor="r-int"><Input id="r-int" type="number" min={1} max={90} value={interval} onChange={(e) => setInterval(e.target.value)} /></Field>}
          {frequency === "monthly" && <Field label="Day of the month (1–28)" htmlFor="r-dom"><Input id="r-dom" type="number" min={1} max={28} value={dom} onChange={(e) => setDom(e.target.value)} /></Field>}
          <div className="grid gap-3 sm:grid-cols-2">
            {pricing.products.map((p) => (
              <Field key={p.id} label={p.name} htmlFor={`rq-${p.id}`}>
                <Input id={`rq-${p.id}`} type="number" min={0} value={qty[p.id] ?? ""} onChange={(e) => setQty((v) => ({ ...v, [p.id]: e.target.value }))} placeholder="0" />
              </Field>
            ))}
          </div>
          <Field label="Empty bottles to collect each time" htmlFor="r-ret"><Input id="r-ret" type="number" min={0} value={returns} onChange={(e) => setReturns(e.target.value)} /></Field>
          <SubmitButton>Create recurring order</SubmitButton>
        </>
      )}
    </ActionForm>
  );
}
