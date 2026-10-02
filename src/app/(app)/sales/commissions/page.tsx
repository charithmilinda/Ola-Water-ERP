import type { Metadata } from "next";
import Link from "next/link";
import { Percent } from "lucide-react";
import { requirePermission, can } from "@/lib/access";
import { createClient } from "@/lib/supabase/server";
import { formatLKR } from "@/lib/format";
import { COMMISSION_STATUS, MONTHS, statusBadge } from "@/lib/labels";
import { PageHeader } from "@/components/ui/page-header";
import { Card, CardHeader, Stat } from "@/components/ui/card";
import { Table, Td, Th } from "@/components/ui/table";
import { Badge } from "@/components/ui/badge";
import { EmptyState } from "@/components/ui/empty-state";
import { FormDialog } from "@/components/ui/form-dialog";
import { ReasonDialog } from "@/components/ui/reason-dialog";
import { Field, Input, Select } from "@/components/ui/field";
import { buttonVariants } from "@/components/ui/button";
import { pickMonth } from "../month";
import { adjustCommission, approveCommission, payCommission, prepareCommissions } from "../actions";

export const metadata: Metadata = { title: "Commissions" };

type S = { id: string; statement_no: string; period_year: number; period_month: number; sales_net: number; collections: number; new_customers: number;
  visits: number; sales_target: number; achievement_pct: number | null; sales_commission: number; collection_commission: number; target_bonus: number;
  new_customer_bonus: number; adjustment: number; adjustment_note: string | null; total: number; status: string; paid_via: string | null;
  rep: { id: string; code: string; employee_id: string | null; profile_id: string } | null };

export default async function CommissionsPage({ searchParams }: { searchParams: Promise<{ m?: string }> }) {
  const access = await requirePermission(["sales_reps.manage", "payroll.approve", "expenses.approve"]);
  const sp = await searchParams;
  const prev = new Date(); prev.setDate(1); prev.setMonth(prev.getMonth() - 1);
  const mo = pickMonth(sp.m ?? `${prev.getFullYear()}-${String(prev.getMonth() + 1).padStart(2, "0")}`);
  const supabase = await createClient();
  const [{ data }, { data: names }, { data: money }] = await Promise.all([
    supabase.from("commission_statements").select("*, rep:sales_reps(id, code, employee_id, profile_id)").eq("period_year", mo.year).eq("period_month", mo.month).order("statement_no"),
    supabase.rpc("staff_directory"),
    supabase.from("money_accounts").select("id, name, kind").eq("is_active", true).in("kind", ["bank", "cash"]).order("kind"),
  ]);
  const list = (data ?? []) as unknown as S[];
  const who = Object.fromEntries(((names ?? []) as { id: string; full_name: string }[]).map((x) => [x.id, x.full_name]));
  const manage = can(access, "sales_reps.manage");
  const approve = can(access, ["payroll.approve", "expenses.approve"]);
  const total = list.reduce((a, s) => a + Number(s.total), 0);

  return (
    <>
      <PageHeader title="Sales Commissions" description="Prepared after the month ends from each rep's plan, checked, then approved by someone else. Reps on the payroll are paid on their next payslip; others are paid here."
        actions={<div className="flex flex-wrap gap-2">
          <form className="flex items-center gap-1"><Input type="month" name="m" defaultValue={mo.key} className="h-9 w-40" aria-label="Month" />
            <button className={buttonVariants({ variant: "secondary", size: "sm" })}>Show</button></form>
          {manage && <ReasonDialog trigger={`Prepare ${MONTHS[mo.month - 1]}`} triggerVariant="primary" triggerSize="md" title={`Prepare commissions — ${mo.label}`}
            description="Creates (or recalculates the drafts of) a statement for every active rep with a commission plan." reasonRequired={false} confirmLabel="Prepare"
            action={prepareCommissions} hidden={{ month: mo.key }} />}
        </div>} />

      <div className="mb-6 grid gap-4 sm:grid-cols-3">
        <Stat label={`Commission — ${mo.label}`} value={formatLKR(total)} hint={`${list.length} rep(s)`} />
        <Stat label="Waiting for approval" value={list.filter((s) => s.status === "draft").length} />
        <Stat label="Approved, not paid yet" value={formatLKR(list.filter((s) => s.status === "approved").reduce((a, s) => a + Number(s.total), 0))} />
      </div>

      <Card>
        <CardHeader title={`Statements — ${mo.label}`} />
        {list.length === 0 ? <EmptyState icon={Percent} title="Nothing prepared for this month" description={manage ? "Press Prepare after the month has ended." : undefined} /> : (
          <Table>
            <thead><tr><Th>Rep</Th><Th className="text-right">Sales</Th><Th className="text-right">Collections</Th><Th className="text-right">Target</Th>
              <Th>Made up of</Th><Th className="text-right">Commission</Th><Th>Status</Th><Th /></tr></thead>
            <tbody>{list.map((s) => { const st = statusBadge(COMMISSION_STATUS, s.status); return (
              <tr key={s.id}>
                <Td>{s.rep ? <Link href={`/sales/reps/${s.rep.id}`} className="font-medium text-ola-700 hover:underline">{who[s.rep.profile_id] ?? s.rep.code}</Link> : "—"}
                  <span className="block font-mono text-xs text-muted">{s.statement_no}</span></Td>
                <Td className="num text-right">{formatLKR(s.sales_net)}<span className="block text-xs text-muted">{s.new_customers} new · {s.visits} visits</span></Td>
                <Td className="num text-right">{formatLKR(s.collections)}</Td>
                <Td className="num text-right">{Number(s.sales_target) ? <>{formatLKR(s.sales_target)}<span className="block text-xs text-muted">{s.achievement_pct}%</span></> : "—"}</Td>
                <Td className="text-xs text-muted">Sales {formatLKR(s.sales_commission)} · collections {formatLKR(s.collection_commission)}
                  {Number(s.target_bonus) > 0 && ` · target bonus ${formatLKR(s.target_bonus)}`}{Number(s.new_customer_bonus) > 0 && ` · new customers ${formatLKR(s.new_customer_bonus)}`}
                  {Number(s.adjustment) !== 0 && <span className="block">Adjustment {formatLKR(s.adjustment)} — {s.adjustment_note}</span>}</Td>
                <Td className="num text-right font-semibold">{formatLKR(s.total)}</Td>
                <Td><Badge tone={st.tone}>{st.label}</Badge>{s.paid_via && <span className="block text-xs text-muted">{s.paid_via === "payroll" ? "On payslip" : "Paid directly"}</span>}
                  {s.status === "approved" && s.rep?.employee_id && <span className="block text-xs text-muted">Goes on the next payslip</span>}</Td>
                <Td className="space-x-1 whitespace-nowrap text-right">
                  {manage && s.status === "draft" && (
                    <FormDialog trigger="Adjust" triggerVariant="ghost" title={`Adjust ${s.statement_no}`} description="Add (or, with a minus, deduct) an amount, e.g. a one-off bonus." submitLabel="Save"
                      action={adjustCommission} hidden={{ statement_id: s.id }}>
                      <Field label="Adjustment (Rs.)" htmlFor={`ad-${s.id}`}><Input id={`ad-${s.id}`} name="amount" type="number" step="0.01" defaultValue={Number(s.adjustment) || ""} /></Field>
                      <Field label="Why" htmlFor={`adn-${s.id}`}><Input id={`adn-${s.id}`} name="note" defaultValue={s.adjustment_note ?? ""} /></Field>
                    </FormDialog>)}
                  {approve && s.status === "draft" && s.rep?.profile_id !== access.user_id && (
                    <ReasonDialog trigger="Approve" triggerVariant="primary" title={`Approve ${s.statement_no}`} description={`${formatLKR(s.total)} — figures are recalculated first.`}
                      reasonRequired={false} confirmLabel="Approve" action={approveCommission} hidden={{ statement_id: s.id }} />)}
                  {can(access, "payments.manage") && s.status === "approved" && (
                    <FormDialog trigger="Pay" triggerVariant="secondary" title={`Pay ${s.statement_no}`} description={`${formatLKR(s.total)}${s.rep?.employee_id ? " — this rep is on the payroll; paying here takes it off the payslip." : ""}`}
                      submitLabel="Record payment" action={payCommission} hidden={{ statement_id: s.id }}>
                      <Field label="Paid from" htmlFor={`pc-${s.id}`}><Select id={`pc-${s.id}`} name="money_account_id">{money?.map((m) => <option key={m.id} value={m.id}>{m.name}</option>)}</Select></Field>
                      <Field label="Transfer reference" htmlFor={`pcr-${s.id}`} hint="Required for bank payments"><Input id={`pcr-${s.id}`} name="reference" /></Field>
                    </FormDialog>)}
                </Td>
              </tr>); })}</tbody>
          </Table>
        )}
      </Card>
    </>
  );
}
