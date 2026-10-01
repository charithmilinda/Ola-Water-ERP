import { formatLKR, formatQty } from "@/lib/format";
import { MONTHS } from "@/lib/labels";

export type PayslipData = {
  payslip: { emp_no: string; employee_name: string; department: string | null; position: string | null; epf_no: string | null; bank_name: string | null;
    bank_account_no: string | null; pay_basis: string; basic: number; days_paid: number; nopay_days: number; nopay_amount: number; ot_hours: number; ot_amount: number;
    gross: number; epf_employee: number; epf_employer: number; etf: number; apit: number; advance_recovery: number; total_deductions: number; net: number };
  run: { run_no: string; year: number; month: number; status: string };
  lines: { name: string; kind: string; amount: number }[];
  company: { name: string | null };
  rates: { epf_employee: number; epf_employer: number; etf: number };
};

/** One A5-sized payslip. */
export function PayslipView({ d }: { d: PayslipData }) {
  const s = d.payslip;
  const row = (l: string, v: number, neg = false) => (
    <div className="flex justify-between py-0.5"><span>{l}</span><span className="tabular-nums">{neg ? "(" : ""}{formatLKR(v).replace("Rs. ", "")}{neg ? ")" : ""}</span></div>
  );
  return (
    <div className="mx-auto mb-6 w-[148mm] break-after-page border border-line bg-white p-6 text-[12px] text-ink print:mb-0 print:border-0">
      <div className="flex items-start justify-between border-b border-line pb-2">
        <div><p className="text-base font-bold">{d.company.name ?? "OLA Water"}</p><p className="text-muted">Payslip — {MONTHS[d.run.month - 1]} {d.run.year}</p></div>
        <div className="text-right text-muted"><p className="font-mono">{d.run.run_no}</p>{d.run.status === "draft" && <p className="font-bold text-red-700">DRAFT</p>}</div>
      </div>
      <div className="mt-2 grid grid-cols-2 gap-x-6">
        <p><span className="text-muted">Name:</span> {s.employee_name}</p><p><span className="text-muted">Emp. no.:</span> {s.emp_no}</p>
        <p><span className="text-muted">Department:</span> {s.department ?? "—"}</p><p><span className="text-muted">EPF no.:</span> {s.epf_no ?? "—"}</p>
        <p><span className="text-muted">Position:</span> {s.position ?? "—"}</p>
        <p><span className="text-muted">{s.pay_basis === "daily" ? "Days worked" : "Days paid"}:</span> {formatQty(s.days_paid)}</p>
      </div>
      <div className="mt-3 grid grid-cols-2 gap-6">
        <div>
          <p className="border-b border-line font-semibold">Earnings</p>
          {row(s.pay_basis === "daily" ? "Wages" : "Basic salary", s.basic)}
          {Number(s.nopay_amount) > 0 && row(`No-pay (${formatQty(s.nopay_days)} days)`, s.nopay_amount, true)}
          {Number(s.ot_amount) > 0 && row(`Overtime (${formatQty(s.ot_hours)} h)`, s.ot_amount)}
          {d.lines.filter((l) => l.kind === "earning").map((l, i) => <div key={i}>{row(l.name, l.amount)}</div>)}
          <div className="mt-1 border-t border-line pt-1 font-semibold">{row("Gross pay", s.gross)}</div>
        </div>
        <div>
          <p className="border-b border-line font-semibold">Deductions</p>
          {Number(s.epf_employee) > 0 && row(`EPF ${d.rates.epf_employee}%`, s.epf_employee)}
          {Number(s.apit) > 0 && row("APIT", s.apit)}
          {Number(s.advance_recovery) > 0 && row("Salary advance", s.advance_recovery)}
          {d.lines.filter((l) => l.kind === "deduction").map((l, i) => <div key={i}>{row(l.name, l.amount)}</div>)}
          <div className="mt-1 border-t border-line pt-1 font-semibold">{row("Total deductions", s.total_deductions)}</div>
        </div>
      </div>
      <div className="mt-3 flex items-center justify-between rounded bg-surface px-3 py-2 text-sm font-bold print:bg-white print:ring-1 print:ring-line">
        <span>Net pay</span><span className="tabular-nums">{formatLKR(s.net)}</span>
      </div>
      <p className="mt-2 text-muted">Paid to {[s.bank_name, s.bank_account_no].filter(Boolean).join(" ") || "—"} · Employer contributions: EPF {d.rates.epf_employer}% {formatLKR(s.epf_employer)},
        ETF {d.rates.etf}% {formatLKR(s.etf)}</p>
    </div>
  );
}
