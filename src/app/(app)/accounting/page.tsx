import type { Metadata } from "next";
import Link from "next/link";
import { BookOpen, Landmark } from "lucide-react";
import { REPORTS } from "@/lib/reports";
import { requirePermission, can } from "@/lib/access";
import { createClient } from "@/lib/supabase/server";
import { formatDate, formatLKR } from "@/lib/format";
import { PageHeader } from "@/components/ui/page-header";
import { Card, CardHeader, Stat } from "@/components/ui/card";
import { Table, Td, Th } from "@/components/ui/table";
import { Badge } from "@/components/ui/badge";
import { Alert } from "@/components/ui/alert";
import { FormDialog } from "@/components/ui/form-dialog";
import { ReasonDialog } from "@/components/ui/reason-dialog";
import { Field, Input } from "@/components/ui/field";
import { closePeriod, openYear } from "./actions";

export const metadata: Metadata = { title: "Accounting" };

type Overview = {
  money: { id: string; name: string; kind: string; code: string; balance: number; last_reconciled: string | null; is_active: boolean }[];
  other_cash: { code: string; name: string; balance: number }[];
  receivable: number; receivable_overdue: number; payable: number; vat_balance: number; deposits_held: number;
  cheques_in_hand: { count: number; amount: number }; cheques_deposited: number; journals_waiting: number; expenses_waiting: number; bills_to_pay: number;
  month: { income: number; expense: number };
  periods: { id: string; name: string; starts_on: string; ends_on: string; status: string; closed_at: string | null }[];
};



export default async function AccountingPage() {
  const access = await requirePermission(["accounting.view", "payments.manage"]);
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("accounting_overview");
  if (error) return <Alert tone="error">{error.message}</Alert>;
  const o = data as Overview;
  const today = new Date().toISOString().slice(0, 10);
  const closeable = o.periods.filter((p) => p.status === "open" && p.ends_on < today);
  const view = can(access, "accounting.view");

  return (
    <>
      <PageHeader title="Accounting" description="Every sale, payment, purchase and expense posts here automatically. Reports are always up to date."
        actions={can(access, "accounting.period_close") && (
          <FormDialog trigger="Open a new year" triggerSize="md" title="Open accounting year" description="Creates the twelve monthly periods for postings in that calendar year."
            submitLabel="Open year" action={openYear}>
            <Field label="Year" htmlFor="oy" required><Input id="oy" name="year" type="number" min={2020} max={2100} defaultValue={new Date().getFullYear() + 1} required /></Field>
          </FormDialog>
        )} />

      {(o.journals_waiting > 0 || o.expenses_waiting > 0 || o.cheques_in_hand.count > 0) && (
        <div className="mb-6 space-y-2">
          {o.journals_waiting > 0 && <Alert tone="warning"><Link href="/accounting/journals" className="font-semibold underline">{o.journals_waiting} manual journal(s)</Link> waiting for approval.</Alert>}
          {o.expenses_waiting > 0 && <Alert tone="warning"><Link href="/expenses" className="font-semibold underline">{o.expenses_waiting} expense(s)</Link> waiting for approval.</Alert>}
          {o.cheques_in_hand.count > 0 && <Alert tone="info"><Link href="/accounting/banking" className="font-semibold underline">{o.cheques_in_hand.count} cheque(s)</Link> in hand ({formatLKR(o.cheques_in_hand.amount)}) — bank them.</Alert>}
        </div>
      )}

      <div className="mb-6 grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <Stat label="Customers owe" value={formatLKR(o.receivable)} hint={`${formatLKR(o.receivable_overdue)} overdue`} />
        <Stat label="We owe suppliers" value={formatLKR(o.payable)} hint={o.bills_to_pay ? `${o.bills_to_pay} bill(s) to pay` : undefined} />
        <Stat label="VAT payable" value={formatLKR(o.vat_balance)} hint="Output VAT less input VAT not yet settled" />
        <Stat label="This month" value={formatLKR(Number(o.month.income) - Number(o.month.expense))} hint={`Income ${formatLKR(o.month.income)} · costs ${formatLKR(o.month.expense)}`} />
      </div>

      <div className="grid gap-6 lg:grid-cols-2">
        <Card>
          <CardHeader title="Cash and bank" actions={<Link href="/accounting/banking" className="text-sm text-ola-700 hover:underline">Banking & cheques →</Link>} />
          <Table>
            <tbody>
              {o.money.filter((m) => m.is_active).map((m) => (
                <tr key={m.id}><Td><span className="font-medium">{m.name}</span><span className="block text-xs text-muted">{m.code}{m.kind === "bank" && (m.last_reconciled ? ` · reconciled to ${formatDate(m.last_reconciled)}` : " · never reconciled")}</span></Td>
                  <Td className={`num text-right ${Number(m.balance) < 0 ? "text-red-700" : ""}`}>{formatLKR(m.balance)}</Td></tr>
              ))}
              {o.other_cash.filter((x) => Number(x.balance) !== 0).map((x) => (
                <tr key={x.code}><Td><span>{x.name}</span><span className="block text-xs text-muted">{x.code} · not yet handed in / banked</span></Td><Td className="num text-right">{formatLKR(x.balance)}</Td></tr>
              ))}
              <tr><Td className="text-muted">Bottle deposits held for customers (liability)</Td><Td className="num text-right text-muted">{formatLKR(o.deposits_held)}</Td></tr>
            </tbody>
          </Table>
        </Card>

        {view && (
          <Card>
            <CardHeader title="Reports" />
            <ul className="divide-y divide-line">
              {REPORTS.map((r) => (
                <li key={r.slug}><Link href={`/accounting/reports/${r.slug}`} className="flex items-start gap-3 px-5 py-3 hover:bg-ola-50/40">
                  <r.icon className="mt-0.5 h-4 w-4 text-ola-600" /><span><span className="font-medium text-ola-700">{r.title}</span><span className="block text-xs text-muted">{r.description}</span></span></Link></li>
              ))}
              <li><Link href="/accounting/ledger" className="flex items-start gap-3 px-5 py-3 hover:bg-ola-50/40"><BookOpen className="mt-0.5 h-4 w-4 text-ola-600" />
                <span><span className="font-medium text-ola-700">General ledger</span><span className="block text-xs text-muted">Every posting to one account, with a running balance</span></span></Link></li>
              <li><Link href="/accounting/accounts" className="flex items-start gap-3 px-5 py-3 hover:bg-ola-50/40"><Landmark className="mt-0.5 h-4 w-4 text-ola-600" />
                <span><span className="font-medium text-ola-700">Chart of accounts</span><span className="block text-xs text-muted">Accounts and their balances</span></span></Link></li>
            </ul>
          </Card>
        )}

        {view && (
          <Card className="lg:col-span-2">
            <CardHeader title="Accounting periods" description="Close a month when its books are final. Nothing can be posted into a closed month; corrections go into an open month." />
            <Table>
              <thead><tr><Th>Month</Th><Th>Dates</Th><Th>Status</Th><Th /></tr></thead>
              <tbody>{o.periods.map((p) => (
                <tr key={p.id}><Td className="font-medium">{p.name}</Td><Td>{formatDate(p.starts_on)} – {formatDate(p.ends_on)}</Td>
                  <Td>{p.status === "closed" ? <Badge tone="neutral">Closed {p.closed_at ? formatDate(p.closed_at) : ""}</Badge> : <Badge tone="green">Open</Badge>}</Td>
                  <Td className="text-right">{can(access, "accounting.period_close") && closeable.some((c) => c.id === p.id) && (
                    <ReasonDialog trigger="Close month" title={`Close ${p.name}`} description="This cannot be undone. Check the trial balance and bank reconciliation first."
                      confirmLabel="Close month" action={closePeriod} hidden={{ period_id: p.id }} />
                  )}</Td></tr>
              ))}</tbody>
            </Table>
          </Card>
        )}
      </div>
    </>
  );
}
