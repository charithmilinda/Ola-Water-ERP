import { notFound } from "next/navigation";
import { getAccess } from "@/lib/access";
import { createClient } from "@/lib/supabase/server";
import { isUuid } from "@/lib/actions";
import { formatDate, formatLKR, formatQty } from "@/lib/format";
import { AutoPrint } from "../../labels/[id]/auto-print";

export const dynamic = "force-dynamic";

type Details = {
  order: { po_no: string; status: string; order_date: string; expected_date: string | null; subtotal: number; tax_total: number; total: number; notes: string | null;
    location: string; approved_by_name: string | null; created_by_name: string | null };
  supplier: { name: string; address: string | null; city: string | null; phone: string | null; email: string | null; vat_no: string | null; payment_terms_days: number };
  company: { name: string | null; vat_no: string | null };
  lines: { line_no: number; name: string; sku: string; unit: string; qty_ordered: number; unit_price: number; tax_rate: number; net: number; tax: number; total: number }[];
};

export default async function PrintPurchaseOrder({ params }: { params: Promise<{ id: string }> }) {
  await getAccess();
  const { id } = await params;
  if (!isUuid(id)) notFound();
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("purchase_order_details", { p_po: id });
  if (error || !data) notFound();
  const d = data as Details;
  const o = d.order;
  if (o.status === "pending_approval" || o.status === "cancelled") notFound();

  return (
    <div className="min-h-dvh bg-surface print:bg-white">
      <div className="no-print flex items-center justify-between bg-navy-900 px-4 py-2 text-white">
        <span className="text-sm">Purchase order — use “Save as PDF” in the print window to email it.</span>
        <AutoPrint />
      </div>
      <div className="mx-auto max-w-[210mm] bg-white p-8 text-[13px] text-ink print:p-0">
        <header className="flex items-start justify-between border-b border-line pb-4">
          <div>
            <h1 className="text-xl font-bold">{d.company.name ?? "OLA Water"}</h1>
            {d.company.vat_no && <p className="text-muted">VAT Reg. No. {d.company.vat_no}</p>}
          </div>
          <div className="text-right">
            <h2 className="text-lg font-semibold">PURCHASE ORDER</h2>
            <p className="font-mono">{o.po_no}</p>
            <p>Date {formatDate(o.order_date)}</p>
          </div>
        </header>
        <section className="mt-4 grid grid-cols-2 gap-6">
          <div>
            <p className="text-xs font-semibold uppercase text-muted">Supplier</p>
            <p className="font-semibold">{d.supplier.name}</p>
            {d.supplier.address && <p>{d.supplier.address}</p>}
            {d.supplier.city && <p>{d.supplier.city}</p>}
            {d.supplier.phone && <p>{d.supplier.phone}</p>}
            {d.supplier.vat_no && <p>VAT {d.supplier.vat_no}</p>}
          </div>
          <div>
            <p className="text-xs font-semibold uppercase text-muted">Deliver to</p>
            <p className="font-semibold">{o.location}</p>
            {o.expected_date && <p>Required by {formatDate(o.expected_date)}</p>}
            <p>Payment terms: {d.supplier.payment_terms_days === 0 ? "cash on delivery" : `${d.supplier.payment_terms_days} days from invoice`}</p>
          </div>
        </section>
        <table className="mt-6 w-full border-collapse">
          <thead><tr className="border-b border-line text-left text-muted"><th className="py-1">#</th><th>Item</th><th className="text-right">Qty</th>
            <th className="text-right">Unit price</th><th className="text-right">VAT</th><th className="text-right">Amount</th></tr></thead>
          <tbody>
            {d.lines.map((l) => (
              <tr key={l.line_no} className="border-b border-line/50">
                <td className="py-1">{l.line_no}</td><td>{l.name} <span className="text-muted">({l.sku})</span></td>
                <td className="text-right">{formatQty(l.qty_ordered)} {l.unit}</td><td className="text-right tabular-nums">{formatLKR(l.unit_price)}</td>
                <td className="text-right">{Number(l.tax_rate) ? `${Number(l.tax_rate)}%` : "—"}</td><td className="text-right tabular-nums">{formatLKR(l.total)}</td>
              </tr>
            ))}
          </tbody>
        </table>
        <div className="mt-3 ml-auto w-64 space-y-1">
          <div className="flex justify-between"><span>Subtotal</span><span className="tabular-nums">{formatLKR(o.subtotal)}</span></div>
          <div className="flex justify-between"><span>VAT</span><span className="tabular-nums">{formatLKR(o.tax_total)}</span></div>
          <div className="flex justify-between border-t border-line pt-1 font-semibold"><span>Total</span><span className="tabular-nums">{formatLKR(o.total)}</span></div>
        </div>
        {o.notes && <p className="mt-6"><span className="font-semibold">Notes:</span> {o.notes}</p>}
        <p className="mt-6 text-muted">Please quote {o.po_no} on your delivery note and invoice. Goods are checked on arrival; damaged or wrong items are returned.</p>
        <footer className="mt-12 grid grid-cols-2 gap-16 text-muted">
          <div className="border-t border-line pt-1">Prepared by {o.created_by_name ?? ""}</div>
          <div className="border-t border-line pt-1">Approved by {o.approved_by_name ?? ""}</div>
        </footer>
      </div>
    </div>
  );
}
