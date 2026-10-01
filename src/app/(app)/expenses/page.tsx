import type { Metadata } from "next";
import Link from "next/link";
import { Plus, Receipt } from "lucide-react";
import { requirePermission, can } from "@/lib/access";
import { createClient } from "@/lib/supabase/server";
import { formatDate, formatLKR, humanize, todayISO } from "@/lib/format";
import { PageHeader } from "@/components/ui/page-header";
import { Card, CardHeader, Stat } from "@/components/ui/card";
import { Table, Td, Th } from "@/components/ui/table";
import { Badge, type BadgeTone } from "@/components/ui/badge";
import { EmptyState } from "@/components/ui/empty-state";
import { FormDialog } from "@/components/ui/form-dialog";
import { ReasonDialog } from "@/components/ui/reason-dialog";
import { Field, Input, Select } from "@/components/ui/field";
import { buttonVariants } from "@/components/ui/button";
import { MethodFields } from "./method-fields";
import { decideExpense, payExpense, recordExpense, saveCategory } from "./actions";

export const metadata: Metadata = { title: "Expenses" };

const STATUS: Record<string, { label: string; tone: BadgeTone }> = {
  pending_approval: { label: "Waiting approval", tone: "amber" }, approved: { label: "Bill to pay", tone: "blue" },
  paid: { label: "Paid", tone: "green" }, rejected: { label: "Rejected", tone: "neutral" },
};
const FILTERS = [["all", "All"], ["pending_approval", "Waiting approval"], ["approved", "Bills to pay"], ["paid", "Paid"]] as const;

type X = { id: string; expense_no: string; expense_date: string; description: string; payee: string | null; net_amount: number; vat_amount: number; total: number;
  pay_method: string; status: string; receipt_path: string | null; decision_note: string | null; created_by: string | null;
  category: { name: string } | null; location: { name: string } | null; vehicle: { registration_no: string } | null };

export default async function ExpensesPage({ searchParams }: { searchParams: Promise<{ show?: string; from?: string; to?: string }> }) {
  const access = await requirePermission(["expenses.view", "expenses.manage"]);
  const sp = await searchParams;
  const show = FILTERS.some(([k]) => k === sp.show) ? sp.show! : "all";
  const today = todayISO();
  const from = sp.from && /^\d{4}-\d{2}-\d{2}$/.test(sp.from) ? sp.from : `${today.slice(0, 8)}01`;
  const supabase = await createClient();
  let q = supabase.from("expenses").select("id, expense_no, expense_date, description, payee, net_amount, vat_amount, total, pay_method, status, receipt_path, decision_note, created_by, category:expense_categories(name), location:locations(name), vehicle:vehicles(registration_no)")
    .order("expense_date", { ascending: false }).order("created_at", { ascending: false }).limit(200);
  q = show === "all" ? q.gte("expense_date", from) : q.eq("status", show);
  const [{ data: rows }, { data: cats }, { data: money }, { data: suppliers }, { data: locations }, { data: vehicles }, { data: accounts }, { data: me }] = await Promise.all([
    q,
    supabase.from("expense_categories").select("id, code, name, account_id, is_active").order("sort_order"),
    supabase.from("money_accounts").select("id, name, kind").eq("is_active", true).order("is_default", { ascending: false }),
    supabase.from("suppliers").select("id, name").eq("is_active", true).order("name"),
    supabase.from("locations").select("id, name").in("location_type", ["head_office", "warehouse", "water_shop"]).eq("is_active", true).order("name"),
    supabase.from("vehicles").select("id, registration_no, name").eq("is_active", true).order("registration_no"),
    supabase.from("accounts").select("id, code, name").eq("account_type", "expense").eq("is_postable", true).eq("is_active", true).order("code"),
    supabase.auth.getUser(),
  ]);
  const list = (rows ?? []) as unknown as X[];
  const receipts: Record<string, string> = {};
  for (const x of list.filter((r) => r.receipt_path).slice(0, 60)) {
    const { data: u } = await supabase.storage.from("expense-receipts").createSignedUrl(x.receipt_path!, 3600);
    if (u?.signedUrl) receipts[x.id] = u.signedUrl;
  }
  const monthTotal = list.filter((x) => x.status !== "rejected" && x.expense_date >= from).reduce((a, x) => a + Number(x.total), 0);
  const waiting = list.filter((x) => x.status === "pending_approval").length;
  const approve = can(access, "expenses.approve");
  const accName = Object.fromEntries((accounts ?? []).map((a) => [a.id, `${a.code} ${a.name}`]));

  return (
    <>
      <PageHeader title="Expenses" description="Fuel, electricity, rent, repairs and other costs. Above the approval limit an expense waits for a manager; once approved it is posted to the accounts."
        actions={can(access, "expenses.manage") && (
          <FormDialog trigger={<><Plus className="h-4 w-4" /> New expense</>} triggerVariant="primary" triggerSize="md" title="Record an expense" submitLabel="Save expense" action={recordExpense} wide>
            <div className="grid gap-4 sm:grid-cols-3">
              <Field label="Category" htmlFor="ex-c" required><Select id="ex-c" name="category_id" required>{cats?.filter((c) => c.is_active).map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}</Select></Field>
              <Field label="Date" htmlFor="ex-d"><Input id="ex-d" name="expense_date" type="date" defaultValue={today} max={today} /></Field>
              <Field label="Paid to" htmlFor="ex-p"><Input id="ex-p" name="payee" placeholder="e.g. Ceylon Electricity Board" /></Field>
            </div>
            <Field label="What for" htmlFor="ex-desc" required><Input id="ex-desc" name="description" required /></Field>
            <div className="grid gap-4 sm:grid-cols-3">
              <Field label="Amount before VAT (Rs.)" htmlFor="ex-n" required><Input id="ex-n" name="net_amount" type="number" min={0.01} step="0.01" required /></Field>
              <Field label="VAT (Rs.)" htmlFor="ex-v" hint="Only if the bill shows VAT you can claim"><Input id="ex-v" name="vat_amount" type="number" min={0} step="0.01" defaultValue={0} /></Field>
              <Field label="Supplier (optional)" htmlFor="ex-s"><Select id="ex-s" name="supplier_id" defaultValue=""><option value="">—</option>{suppliers?.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}</Select></Field>
              <Field label="Location (optional)" htmlFor="ex-l"><Select id="ex-l" name="location_id" defaultValue=""><option value="">—</option>{locations?.map((l) => <option key={l.id} value={l.id}>{l.name}</option>)}</Select></Field>
              <Field label="Vehicle (optional)" htmlFor="ex-veh"><Select id="ex-veh" name="vehicle_id" defaultValue=""><option value="">—</option>{vehicles?.map((v) => <option key={v.id} value={v.id}>{v.registration_no}{v.name ? ` — ${v.name}` : ""}</option>)}</Select></Field>
              <Field label="Receipt / bill" htmlFor="ex-f" hint="Photo or PDF, up to 10 MB"><Input id="ex-f" name="receipt" type="file" accept="image/*,application/pdf" className="py-1.5" /></Field>
            </div>
            <MethodFields accounts={money ?? []} />
          </FormDialog>
        )} />

      <div className="mb-6 grid gap-4 sm:grid-cols-3">
        <Stat label={show === "all" ? `Since ${formatDate(from)}` : "Shown"} value={formatLKR(monthTotal)} hint="Including VAT, excluding rejected" />
        <Stat label="Waiting approval" value={waiting} />
        <Stat label="Bills to pay" value={formatLKR(list.filter((x) => x.status === "approved").reduce((a, x) => a + Number(x.total), 0))} />
      </div>

      <Card className="mb-6">
        <CardHeader title="Expenses" actions={<div className="flex flex-wrap gap-1">{FILTERS.map(([k, l]) => (
          <Link key={k} href={`/expenses?show=${k}`} className={buttonVariants({ variant: k === show ? "primary" : "secondary", size: "sm" })}>{l}</Link>))}</div>} />
        {list.length === 0 ? <EmptyState icon={Receipt} title="No expenses here" /> : (
          <Table>
            <thead><tr><Th>Expense</Th><Th>Category</Th><Th>Date</Th><Th className="text-right">Amount</Th><Th>Status</Th><Th /></tr></thead>
            <tbody>{list.map((x) => { const st = STATUS[x.status]; return (
              <tr key={x.id}>
                <Td><span className="font-medium">{x.description}</span><span className="block text-xs text-muted">{x.expense_no}{x.payee && ` · ${x.payee}`}
                  {x.location && ` · ${x.location.name}`}{x.vehicle && ` · ${x.vehicle.registration_no}`}</span>
                  {receipts[x.id] && <a href={receipts[x.id]} target="_blank" rel="noreferrer" className="text-xs text-ola-700 hover:underline">Receipt</a>}</Td>
                <Td>{x.category?.name}</Td>
                <Td className="whitespace-nowrap">{formatDate(x.expense_date)}</Td>
                <Td className="num text-right">{formatLKR(x.total)}{Number(x.vat_amount) > 0 && <span className="block text-xs text-muted">incl. VAT {formatLKR(x.vat_amount)}</span>}
                  <span className="block text-xs text-muted">{x.pay_method === "on_credit" ? "On credit" : humanize(x.pay_method)}</span></Td>
                <Td><Badge tone={st.tone}>{st.label}</Badge>{x.decision_note && <span className="block text-xs text-muted">{x.decision_note}</span>}</Td>
                <Td className="space-x-1 whitespace-nowrap text-right">
                  {approve && x.status === "pending_approval" && x.created_by !== me.user?.id && (
                    <>
                      <ReasonDialog trigger="Approve" triggerVariant="primary" title={`Approve ${x.expense_no}`} reasonRequired={false} confirmLabel="Approve"
                        description={`${x.description} — ${formatLKR(x.total)}`} action={decideExpense} hidden={{ expense_id: x.id, decision: "approve" }} />
                      <ReasonDialog trigger="Reject" triggerVariant="dangerOutline" title={`Reject ${x.expense_no}`} confirmLabel="Reject" confirmVariant="danger"
                        action={decideExpense} hidden={{ expense_id: x.id, decision: "reject" }} />
                    </>
                  )}
                  {can(access, "payments.manage") && x.status === "approved" && (
                    <FormDialog trigger="Pay" title={`Pay ${x.expense_no}`} description={`${x.payee ?? x.description} — ${formatLKR(x.total)}`} submitLabel="Record payment"
                      action={payExpense} hidden={{ expense_id: x.id }}>
                      <Field label="Paid from" htmlFor={`pe-${x.id}`}><Select id={`pe-${x.id}`} name="money_account_id">{money?.filter((m) => m.kind !== "card_clearing").map((m) => <option key={m.id} value={m.id}>{m.name}</option>)}</Select></Field>
                      <Field label="Reference / cheque no." htmlFor={`per-${x.id}`} hint="Required when paid from a bank"><Input id={`per-${x.id}`} name="reference" /></Field>
                    </FormDialog>
                  )}
                </Td>
              </tr>); })}</tbody>
          </Table>
        )}
      </Card>

      <Card>
        <CardHeader title="Expense categories" description="Each category posts to an expense account." actions={approve && (
          <FormDialog trigger={<><Plus className="h-4 w-4" /> Add</>} title="New expense category" submitLabel="Save" action={saveCategory}>
            <div className="grid gap-4 sm:grid-cols-2">
              <Field label="Code" htmlFor="ec-c" required><Input id="ec-c" name="code" required placeholder="SECURITY" /></Field>
              <Field label="Name" htmlFor="ec-n" required><Input id="ec-n" name="name" required /></Field>
            </div>
            <Field label="Expense account" htmlFor="ec-a"><Select id="ec-a" name="account_id">{accounts?.map((a) => <option key={a.id} value={a.id}>{a.code} {a.name}</option>)}</Select></Field>
          </FormDialog>
        )} />
        <Table>
          <tbody>{cats?.map((c) => (
            <tr key={c.id} className={c.is_active ? "" : "opacity-50"}><Td className="font-medium">{c.name}</Td><Td className="text-sm text-muted">{accName[c.account_id]}</Td>
              <Td className="text-right">{approve && (
                <FormDialog trigger="Edit" triggerVariant="ghost" title={`Edit ${c.name}`} submitLabel="Save" action={saveCategory} hidden={{ id: c.id, code: c.code }}>
                  <Field label="Name" htmlFor={`ecn-${c.id}`}><Input id={`ecn-${c.id}`} name="name" defaultValue={c.name} required /></Field>
                  <Field label="Expense account" htmlFor={`eca-${c.id}`}><Select id={`eca-${c.id}`} name="account_id" defaultValue={c.account_id}>{accounts?.map((a) => <option key={a.id} value={a.id}>{a.code} {a.name}</option>)}</Select></Field>
                  <label className="flex items-center gap-2 text-sm"><input type="checkbox" name="is_active" defaultChecked={c.is_active} /> Active</label>
                </FormDialog>
              )}</Td></tr>
          ))}</tbody>
        </Table>
      </Card>
    </>
  );
}
