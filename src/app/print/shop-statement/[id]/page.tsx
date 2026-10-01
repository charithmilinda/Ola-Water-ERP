import { notFound } from "next/navigation";
import { getAccess } from "@/lib/access";
import { createClient } from "@/lib/supabase/server";
import { isUuid } from "@/lib/actions";
import { formatDate, formatDateTime, formatLKR, humanize, todayISO } from "@/lib/format";
import { AutoPrint } from "../../labels/[id]/auto-print";

export const dynamic = "force-dynamic";

type Figures = {
  sales_count: number; sales_total: number; net_sales: number; vat: number; deposits_net: number; cash: number; card_qr: number;
  bank_cheque: number; credit: number; cost_of_sales: number; transfers_received: number; payments_to_ola: number; outstanding_to_ola: number;
  open_exceptions: number;
  by_product: { product: string; qty: number; total: number }[];
  stock: { product: string; qty: number; value: number }[];
  bottles: { company: string; type: string; fill_state: string; qty: number }[];
};
type Statement = {
  shop: { name: string; code: string; operating_model: "company_owned" | "dealer"; owner_name: string | null; address: string | null; phone: string | null; commission_percent: number | null };
  company: { name: string | null; vat_no: string | null };
  from: string; to: string; generated_at: string; opening_balance: number | null;
  figures: Figures;
  days: { date: string; sales: number; cash: number; receipts: number }[];
  invoices: { invoice_no: string; date: string; due: string | null; total: number; balance: number }[];
  payments: { payment_no: string; date: string; method: string; amount: number; reference: string | null }[];
  settlements: { settlement_no: string; amount: number; commission: number; created_at: string }[];
};

const isoDate = (v: string | undefined, fallback: string) => (v && /^\d{4}-\d{2}-\d{2}$/.test(v) ? v : fallback);

export default async function ShopStatementPage({ params, searchParams }: {
  params: Promise<{ id: string }>; searchParams: Promise<{ from?: string; to?: string }>;
}) {
  await getAccess();
  const { id } = await params;
  if (!isUuid(id)) notFound();
  const sp = await searchParams;
  const today = todayISO();
  const to = isoDate(sp.to, today);
  const from = isoDate(sp.from, `${to.slice(0, 8)}01`);
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("shop_statement", { p_shop: id, p_from: from, p_to: to });
  if (error || !data) notFound();
  const s = data as Statement;
  const f = s.figures;
  const dealer = s.shop.operating_model === "dealer";

  const row = (label: string, value: number | string, strong = false) => (
    <tr className={strong ? "font-semibold" : ""}>
      <td className="py-1 pr-4">{label}</td>
      <td className="py-1 text-right tabular-nums">{typeof value === "number" ? formatLKR(value) : value}</td>
    </tr>
  );

  let running = s.opening_balance ?? 0;
  const ledger = dealer
    ? [
        ...s.invoices.map((i) => ({ date: i.date, ref: i.invoice_no, desc: "Stock invoice", debit: i.total, credit: 0 })),
        ...s.payments.map((p) => ({ date: p.date.slice(0, 10), ref: p.payment_no, desc: `Payment — ${humanize(p.method)}${p.reference ? ` (${p.reference})` : ""}`, debit: 0, credit: p.amount })),
      ].sort((a, b) => a.date.localeCompare(b.date))
    : [];

  return (
    <div className="min-h-dvh bg-surface print:bg-white">
      <div className="no-print flex items-center justify-between bg-navy-900 px-4 py-2 text-white">
        <span className="text-sm">Shop statement — use “Save as PDF” in the print window to keep a copy.</span>
        <AutoPrint />
      </div>
      <div className="mx-auto max-w-[210mm] bg-white p-8 text-[13px] text-ink print:p-0">
        <header className="flex items-start justify-between border-b border-line pb-4">
          <div>
            <h1 className="text-xl font-bold">{s.company.name ?? "OLA Water"}</h1>
            {s.company.vat_no && <p className="text-muted">VAT Reg. No. {s.company.vat_no}</p>}
          </div>
          <div className="text-right">
            <h2 className="text-lg font-semibold">Shop Statement</h2>
            <p>{formatDate(from)} – {formatDate(to)}</p>
            <p className="text-muted">Printed {formatDateTime(s.generated_at)}</p>
          </div>
        </header>

        <section className="mt-4 grid grid-cols-2 gap-4">
          <div>
            <p className="font-semibold">{s.shop.name} ({s.shop.code})</p>
            <p>{dealer ? "Dealer shop" : "Company-owned shop"}{s.shop.owner_name ? ` — ${s.shop.owner_name}` : ""}</p>
            {s.shop.address && <p>{s.shop.address}</p>}
            {s.shop.phone && <p>{s.shop.phone}</p>}
          </div>
          {f.open_exceptions > 0 && (
            <p className="self-start rounded border border-amber-300 bg-amber-50 p-2 text-amber-900">
              {f.open_exceptions} open issue(s) to resolve for this shop.
            </p>
          )}
        </section>

        <section className="mt-6 grid grid-cols-2 gap-8">
          <table className="w-full">
            <caption className="mb-1 text-left font-semibold">Till sales</caption>
            <tbody>
              {row("Receipts", String(f.sales_count))}
              {row("Sales before VAT", f.net_sales)}
              {row("VAT", f.vat)}
              {row("Bottle deposits (net)", f.deposits_net)}
              {row("Total sales", f.sales_total, true)}
              {row("Cash (net of refunds)", f.cash)}
              {row("Card / QR", f.card_qr)}
              {row("Bank / cheque", f.bank_cheque)}
              {row("On customer account", f.credit)}
            </tbody>
          </table>
          <table className="w-full">
            <caption className="mb-1 text-left font-semibold">{dealer ? "Account with OLA" : "Shop result"}</caption>
            <tbody>
              {dealer ? (
                <>
                  {row("Opening balance", s.opening_balance ?? 0)}
                  {row("Stock invoiced", f.transfers_received)}
                  {row("Paid to OLA", f.payments_to_ola)}
                  {row("Owed to OLA now", f.outstanding_to_ola, true)}
                </>
              ) : (
                <>
                  {row("Cost of goods sold", f.cost_of_sales)}
                  {row("Gross margin", f.net_sales - f.cost_of_sales, true)}
                  {s.shop.commission_percent != null && row("Commission rate", `${s.shop.commission_percent}%`)}
                  {row("Settled in period", s.settlements.reduce((a, x) => a + Number(x.amount), 0))}
                  {row("Commission in period", s.settlements.reduce((a, x) => a + Number(x.commission), 0))}
                </>
              )}
            </tbody>
          </table>
        </section>

        {dealer && (
          <section className="mt-6">
            <h3 className="mb-1 font-semibold">Account activity</h3>
            <table className="w-full border-collapse">
              <thead><tr className="border-b border-line text-left text-muted"><th className="py-1">Date</th><th>Reference</th><th>Details</th><th className="text-right">Charged</th><th className="text-right">Paid</th><th className="text-right">Balance</th></tr></thead>
              <tbody>
                <tr><td className="py-1" colSpan={5}>Opening balance</td><td className="text-right tabular-nums">{formatLKR(running)}</td></tr>
                {ledger.map((l, i) => {
                  running += l.debit - l.credit;
                  return (
                    <tr key={i} className="border-b border-line/50">
                      <td className="py-1">{formatDate(l.date)}</td><td>{l.ref}</td><td>{l.desc}</td>
                      <td className="text-right tabular-nums">{l.debit ? formatLKR(l.debit) : ""}</td>
                      <td className="text-right tabular-nums">{l.credit ? formatLKR(l.credit) : ""}</td>
                      <td className="text-right tabular-nums">{formatLKR(running)}</td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </section>
        )}

        <section className="mt-6 grid grid-cols-2 gap-8">
          <div>
            <h3 className="mb-1 font-semibold">Sales by product</h3>
            <table className="w-full">
              <tbody>
                {f.by_product.length === 0 && <tr><td className="text-muted">No sales.</td></tr>}
                {f.by_product.map((p) => (
                  <tr key={p.product}><td className="py-1">{p.product}</td><td className="text-right">{p.qty}</td><td className="text-right tabular-nums">{formatLKR(p.total)}</td></tr>
                ))}
              </tbody>
            </table>
          </div>
          <div>
            <h3 className="mb-1 font-semibold">Stock and bottles at the shop now</h3>
            <table className="w-full">
              <tbody>
                {f.stock.map((p) => (<tr key={p.product}><td className="py-1">{p.product}</td><td className="text-right">{p.qty}</td></tr>))}
                {f.bottles.map((b, i) => (<tr key={i}><td className="py-1">{b.company} {b.type} — {humanize(b.fill_state)} bottles</td><td className="text-right">{b.qty}</td></tr>))}
                {f.stock.length + f.bottles.length === 0 && <tr><td className="text-muted">Nothing on hand.</td></tr>}
              </tbody>
            </table>
          </div>
        </section>

        <section className="mt-6 break-inside-avoid">
          <h3 className="mb-1 font-semibold">Day by day</h3>
          <table className="w-full border-collapse">
            <thead><tr className="border-b border-line text-left text-muted"><th className="py-1">Date</th><th className="text-right">Receipts</th><th className="text-right">Sales</th><th className="text-right">Cash</th></tr></thead>
            <tbody>
              {s.days.filter((d) => d.receipts > 0).map((d) => (
                <tr key={d.date} className="border-b border-line/50">
                  <td className="py-1">{formatDate(d.date)}</td><td className="text-right">{d.receipts}</td>
                  <td className="text-right tabular-nums">{formatLKR(d.sales)}</td><td className="text-right tabular-nums">{formatLKR(d.cash)}</td>
                </tr>
              ))}
              {s.days.every((d) => d.receipts === 0) && <tr><td className="py-1 text-muted" colSpan={4}>No till sales in this period.</td></tr>}
            </tbody>
          </table>
        </section>

        {s.settlements.length > 0 && (
          <section className="mt-6">
            <h3 className="mb-1 font-semibold">Settlements</h3>
            <table className="w-full">
              <tbody>
                {s.settlements.map((x) => (
                  <tr key={x.settlement_no}><td className="py-1">{x.settlement_no}</td><td>{formatDateTime(x.created_at)}</td>
                    <td className="text-right tabular-nums">{formatLKR(x.amount)}</td>
                    <td className="text-right tabular-nums">{Number(x.commission) ? `Commission ${formatLKR(x.commission)}` : ""}</td></tr>
                ))}
              </tbody>
            </table>
          </section>
        )}

        <footer className="mt-10 grid grid-cols-2 gap-16 text-muted">
          <div className="border-t border-line pt-1">Shop representative</div>
          <div className="border-t border-line pt-1">For {s.company.name ?? "OLA Water"}</div>
        </footer>
      </div>
    </div>
  );
}
