import type { Metadata } from "next";
import Link from "next/link";
import { ArrowLeft, Plus } from "lucide-react";
import { requirePermission, can } from "@/lib/access";
import { createClient } from "@/lib/supabase/server";
import { formatLKR, todayISO } from "@/lib/format";
import { PageHeader } from "@/components/ui/page-header";
import { Card } from "@/components/ui/card";
import { Table, Td, Th } from "@/components/ui/table";
import { Badge } from "@/components/ui/badge";
import { FormDialog } from "@/components/ui/form-dialog";
import { Field, Input, Select } from "@/components/ui/field";
import { saveAccount } from "../actions";

export const metadata: Metadata = { title: "Chart of accounts" };

type Acc = { id: string; code: string; name: string; account_type: string; parent_id: string | null; is_postable: boolean; is_active: boolean;
  system_key: string | null; description: string | null };
const TYPES = [["asset", "Asset"], ["liability", "Liability"], ["equity", "Equity"], ["income", "Income"], ["expense", "Expense"]] as const;

export default async function AccountsPage() {
  const access = await requirePermission("accounting.view");
  const supabase = await createClient();
  const today = todayISO();
  const [{ data: accs }, { data: tb }] = await Promise.all([
    supabase.from("accounts").select("id, code, name, account_type, parent_id, is_postable, is_active, system_key, description").order("code"),
    supabase.rpc("report_trial_balance", { p_from: today, p_to: today }),
  ]);
  const accounts = (accs ?? []) as Acc[];
  const bal = Object.fromEntries(((tb ?? []) as { account_id: string; closing: number; account_type: string }[]).map((r) => [r.account_id,
    ["asset", "expense"].includes(r.account_type) ? Number(r.closing) : -Number(r.closing)]));
  const headings = accounts.filter((a) => !a.is_postable);
  const manage = can(access, "accounting.period_close");

  const fields = (a?: Acc) => {
    const k = a?.id ?? "new";
    return (
      <>
        <div className="grid gap-4 sm:grid-cols-3">
          <Field label="Code" htmlFor={`ac-${k}`} required hint="4–8 digits"><Input id={`ac-${k}`} name="code" defaultValue={a?.code} required disabled={!!a} pattern="[0-9]{4,8}" /></Field>
          <Field label="Name" htmlFor={`an-${k}`} required className="sm:col-span-2"><Input id={`an-${k}`} name="name" defaultValue={a?.name} required /></Field>
          <Field label="Type" htmlFor={`at-${k}`}><Select id={`at-${k}`} name="account_type" defaultValue={a?.account_type ?? "expense"}>{TYPES.map(([v, l]) => <option key={v} value={v}>{l}</option>)}</Select></Field>
          <Field label="Under heading" htmlFor={`ap-${k}`} className="sm:col-span-2"><Select id={`ap-${k}`} name="parent_id" defaultValue={a?.parent_id ?? ""}>
            <option value="">None</option>{headings.filter((h) => h.id !== a?.id).map((h) => <option key={h.id} value={h.id}>{h.code} {h.name}</option>)}</Select></Field>
        </div>
        <Field label="Description" htmlFor={`ad-${k}`}><Input id={`ad-${k}`} name="description" defaultValue={a?.description ?? ""} /></Field>
        <div className="flex flex-wrap gap-6 text-sm">
          <label className="flex items-center gap-2"><input type="checkbox" name="is_postable" defaultChecked={a ? a.is_postable : true} /> Can be posted to (untick for a heading)</label>
          {a && <label className="flex items-center gap-2"><input type="checkbox" name="is_active" defaultChecked={a.is_active} /> Active</label>}
        </div>
        {a?.system_key && <p className="text-xs text-amber-800">Used by automatic postings ({a.system_key}) — it can be renamed but not removed.</p>}
        {a && <Field label="Reason for change" htmlFor={`ar-${k}`}><Input id={`ar-${k}`} name="reason" /></Field>}
      </>
    );
  };

  return (
    <>
      <Link href="/accounting" className="mb-3 inline-flex items-center gap-1 text-sm text-ola-700 hover:underline"><ArrowLeft className="h-4 w-4" /> Accounting</Link>
      <PageHeader title="Chart of accounts" description="A Sri Lankan default chart. Your accountant can add accounts and rename them; accounts with postings keep their type."
        actions={manage && (
          <FormDialog trigger={<><Plus className="h-4 w-4" /> New account</>} triggerVariant="primary" triggerSize="md" title="New account" submitLabel="Add account" action={saveAccount} wide>
            {fields()}
          </FormDialog>
        )} />
      <Card>
        <Table>
          <thead><tr><Th>Account</Th><Th>Type</Th><Th className="text-right">Balance today</Th><Th /></tr></thead>
          <tbody>{accounts.map((a) => (
            <tr key={a.id} className={`${a.is_active ? "" : "opacity-50"} ${a.is_postable ? "" : "bg-surface/60"}`}>
              <Td className={a.parent_id ? "pl-10" : "font-semibold"}>
                {a.is_postable ? <Link href={`/accounting/ledger?account=${a.id}`} className="hover:underline">{a.code} {a.name}</Link> : `${a.code} ${a.name}`}
                {a.description && <span className="block text-xs text-muted">{a.description}</span>}
                {!a.is_active && <Badge tone="neutral" className="ml-2">Inactive</Badge>}
              </Td>
              <Td className="capitalize">{a.account_type}</Td>
              <Td className="num text-right">{a.is_postable ? formatLKR(bal[a.id] ?? 0) : ""}</Td>
              <Td className="text-right">{manage && (
                <FormDialog trigger="Edit" triggerVariant="ghost" title={`Edit ${a.code}`} submitLabel="Save" action={saveAccount} hidden={{ id: a.id, code: a.code }} wide>{fields(a)}</FormDialog>
              )}</Td>
            </tr>
          ))}</tbody>
        </Table>
      </Card>
    </>
  );
}
