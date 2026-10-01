// 80 mm thermal receipt. Used by the office print page and the driver app.

export type ReceiptData = {
  invoice_no: string | null;
  invoice_date?: string;
  created_at?: string;
  is_tax_invoice?: boolean;
  print_count: number;
  subtotal_net: number;
  tax_total: number;
  total: number;
  amount_paid?: number;
  balance?: number;
  company: { name: string; vat_no?: string | null; footer?: string | null };
  customer: { name: string; customer_no: string; vat_no?: string | null };
  staff?: string | null;
  lines: { description: string; qty: number; unit_price: number; discount?: number; total: number; line_type?: string }[];
  payments?: { method: string; amount: number }[];
  paid?: number;
  method?: string | null;
  tendered?: number | null;
  change?: number | null;
  outstanding: number;
  ola_bottles?: number;
  summary?: { bottles?: Bottles } | null;
  bottles?: Bottles;
  pending_sync?: boolean;
};
type Bottles = { issued?: Record<string, number>; returned?: Record<string, number>; external?: { company: string; qty: number }[]; balance?: number };

const rs = (n: number | string | null | undefined) =>
  Number(n ?? 0).toLocaleString("en-LK", { minimumFractionDigits: 2, maximumFractionDigits: 2 });

function when(r: ReceiptData) {
  const d = r.created_at ? new Date(r.created_at) : new Date();
  return new Intl.DateTimeFormat("en-GB", { timeZone: "Asia/Colombo", day: "2-digit", month: "2-digit", year: "numeric", hour: "numeric", minute: "2-digit", hour12: true }).format(d);
}

export function Receipt80({ r }: { r: ReceiptData }) {
  const b = r.bottles ?? r.summary?.bottles;
  const sum = (o?: Record<string, number>) => Object.values(o ?? {}).reduce((a, x) => a + Number(x), 0);
  const paid = r.paid ?? (r.payments ?? []).reduce((a, p) => a + Number(p.amount), 0);
  const method = r.method ?? r.payments?.[0]?.method;
  return (
    <div className="receipt mx-auto w-[80mm] bg-white px-[4mm] py-[5mm] font-mono text-[11.5px] leading-snug text-black shadow-sm print:shadow-none">
      <style>{`@page { size: 80mm auto; margin: 0; } @media print { body { background: #fff; } }`}</style>
      <div className="text-center">
        <svg viewBox="0 0 32 32" className="mx-auto mb-1 h-8 w-8" aria-hidden><rect width="32" height="32" rx="8" fill="#000" /><path d="M16 6c3.6 4.6 7 8.7 7 12.4A7 7 0 0 1 9 18.4C9 14.7 12.4 10.6 16 6Z" fill="#fff" /></svg>
        <div className="text-[14px] font-bold">{r.company.name}</div>
        {r.company.vat_no && <div>VAT No: {r.company.vat_no}</div>}
        <div className="mt-1 font-bold">{r.is_tax_invoice ? "TAX INVOICE" : "RECEIPT"}</div>
        {r.print_count > 0 && <div className="font-bold">*** REPRINT ***</div>}
        {r.pending_sync && <div className="font-bold">*** NOT YET SYNCED ***</div>}
      </div>
      <div className="my-2 border-t border-dashed border-black" />
      <div className="flex justify-between"><span>No:</span><span>{r.invoice_no ?? "Pending"}</span></div>
      <div className="flex justify-between"><span>Date:</span><span>{when(r)}</span></div>
      <div className="flex justify-between"><span>Customer:</span><span className="text-right">{r.customer.name}</span></div>
      <div className="flex justify-between"><span>Cust No:</span><span>{r.customer.customer_no}</span></div>
      {r.customer.vat_no && <div className="flex justify-between"><span>Cust VAT:</span><span>{r.customer.vat_no}</span></div>}
      {r.staff && <div className="flex justify-between"><span>Served by:</span><span>{r.staff}</span></div>}
      <div className="my-2 border-t border-dashed border-black" />
      {r.lines.map((l, i) => (
        <div key={i} className="mb-1">
          <div>{l.description}</div>
          <div className="flex justify-between"><span>{Number(l.qty)} x {rs(l.unit_price)}{Number(l.discount) ? ` - ${rs(l.discount)}` : ""}</span><span>{rs(l.total)}</span></div>
        </div>
      ))}
      <div className="my-2 border-t border-dashed border-black" />
      {Number(r.tax_total) > 0 && (
        <>
          <div className="flex justify-between"><span>Net amount</span><span>{rs(r.subtotal_net)}</span></div>
          <div className="flex justify-between"><span>VAT</span><span>{rs(r.tax_total)}</span></div>
        </>
      )}
      <div className="flex justify-between text-[13px] font-bold"><span>TOTAL Rs.</span><span>{rs(r.total)}</span></div>
      {paid > 0 && <div className="flex justify-between"><span>Paid ({method?.replace("_", " ")})</span><span>{rs(paid)}</span></div>}
      {r.tendered ? <div className="flex justify-between"><span>Tendered</span><span>{rs(r.tendered)}</span></div> : null}
      {r.change ? <div className="flex justify-between"><span>Change</span><span>{rs(r.change)}</span></div> : null}
      <div className="flex justify-between font-bold"><span>Your balance</span><span>{rs(r.outstanding)}</span></div>
      {b && (
        <>
          <div className="my-2 border-t border-dashed border-black" />
          <div className="font-bold">BOTTLES</div>
          <div className="flex justify-between"><span>OLA bottles issued</span><span>{sum(b.issued)}</span></div>
          <div className="flex justify-between"><span>OLA bottles returned</span><span>{sum(b.returned)}</span></div>
          {(b.external ?? []).length > 0 && (
            <div className="flex justify-between"><span>Other bottles taken</span><span>{(b.external ?? []).map((e) => `${e.company} ${e.qty}`).join(", ")}</span></div>
          )}
          <div className="flex justify-between font-bold"><span>OLA bottles you hold</span><span>{b.balance ?? r.ola_bottles ?? 0}</span></div>
        </>
      )}
      <div className="my-2 border-t border-dashed border-black" />
      {r.company.footer && <div className="text-center">{r.company.footer}</div>}
    </div>
  );
}
