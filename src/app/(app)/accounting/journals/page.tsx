import type { Metadata } from "next";
import Link from "next/link";
import { ArrowLeft, Plus, Search } from "lucide-react";
import { requirePermission, can } from "@/lib/access";
import { createClient } from "@/lib/supabase/server";
import { formatDate, formatDateTime, formatLKR, humanize, todayISO } from "@/lib/format";
import { PageHeader } from "@/components/ui/page-header";
import { Card, CardHeader } from "@/components/ui/card";
import { Table, Td, Th } from "@/components/ui/table";
import { Badge } from "@/components/ui/badge";
import { FormDialog } from "@/components/ui/form-dialog";
import { ReasonDialog } from "@/components/ui/reason-dialog";
import { Button } from "@/components/ui/button";
import { Field, Input, Label } from "@/components/ui/field";
import { JournalLines } from "./journal-lines";
import { decideJournal, submitJournal } from "../actions";

export const metadata: Metadata = { title: "Journals" };

type Draft = { id: string; draft_no: string; entry_date: string; description: string; lines: { account_id: string; debit: number; credit: number; memo: string | null }[];
  total: number; reason: string; status: string; created_at: string; created_by: string | null; decision_note: string | null; entry_id: string | null };

export default async function JournalsPage({ searchParams }: { searchParams: Promise<{ from?: string; to?: string; q?: string }> }) {
  const access = await requirePermission(["accounting.view", "accounting.manual_journal"]);
  const sp = await searchParams;
  const today = todayISO();
  const to = sp.to && /^\d{4}-\d{2}-\d{2}$/.test(sp.to) ? sp.to : today;
  const from = sp.from && /^\d{4}-\d{2}-\d{2}$/.test(sp.from) ? sp.from : `${to.slice(0, 8)}01`;
  const supabase = await createClient();
  let q = supabase.from("journal_entries").select("id, entry_no, entry_date, event_type, description, total, reverses_entry_id")
    .gte("entry_date", from).lte("entry_date", to).order("entry_date", { ascending: false }).order("created_at", { ascending: false }).limit(200);
  if (sp.q) q = q.or(`description.ilike.%${sp.q.replace(/[%,()]/g, " ")}%,entry_no.ilike.%${sp.q.replace(/[%,()]/g, " ")}%`);
  const [{ data: entries }, { data: drafts }, { data: accounts }, { data: me }] = await Promise.all([
    q,
    supabase.from("journal_drafts").select("*").order("created_at", { ascending: false }).limit(30),
    supabase.from("accounts").select("id, code, name").eq("is_postable", true).eq("is_active", true).order("code"),
    supabase.auth.getUser(),
  ]);
  const acc = Object.fromEntries((accounts ?? []).map((a) => [a.id, `${a.code} ${a.name}`]));
  const mine = me.user?.id;
  const pending = ((drafts ?? []) as Draft[]).filter((x) => x.status === "pending");
  const decided = ((drafts ?? []) as Draft[]).filter((x) => x.status !== "pending").slice(0, 10);
  const canMj = can(access, "accounting.manual_journal");

  return (
    <>
      <Link href="/accounting" className="mb-3 inline-flex items-center gap-1 text-sm text-ola-700 hover:underline"><ArrowLeft className="h-4 w-4" /> Accounting</Link>
      <PageHeader title="Journals" description="Every accounting entry. Manual journals are prepared by one person and approved by another before they are posted."
        actions={canMj && (
          <FormDialog trigger={<><Plus className="h-4 w-4" /> New manual journal</>} triggerVariant="primary" triggerSize="md" title="New manual journal"
            description="For corrections and entries no screen covers (e.g. accruals, opening balances). Sent for approval." submitLabel="Send for approval" action={submitJournal} wide>
            <div className="grid gap-4 sm:grid-cols-3">
              <Field label="Date" htmlFor="mj-d" required><Input id="mj-d" name="entry_date" type="date" defaultValue={today} required /></Field>
              <Field label="Description" htmlFor="mj-desc" required className="sm:col-span-2"><Input id="mj-desc" name="description" required /></Field>
            </div>
            <JournalLines accounts={accounts ?? []} />
            <Field label="Why is this needed?" htmlFor="mj-r" required hint="Recorded in the audit trail"><Input id="mj-r" name="reason" required /></Field>
          </FormDialog>
        )} />

      {(pending.length > 0 || decided.length > 0) && (
        <Card className="mb-6">
          <CardHeader title="Manual journals" description={pending.length ? `${pending.length} waiting for approval` : undefined} />
          <div className="divide-y divide-line">
            {[...pending, ...decided].map((j) => (
              <div key={j.id} className="px-5 py-3 text-sm">
                <div className="flex flex-wrap items-center justify-between gap-2">
                  <span><span className="font-medium">{j.draft_no}</span> · {formatDate(j.entry_date)} · {j.description} · <span className="num">{formatLKR(j.total)}</span></span>
                  <span className="flex items-center gap-2">
                    {j.status === "pending" ? <Badge tone="amber">Waiting approval</Badge> : j.status === "posted" ? <Badge tone="green">Posted</Badge> : <Badge tone="neutral">{humanize(j.status)}</Badge>}
                    {j.entry_id && <Link href={`/accounting/journals/${j.entry_id}`} className="text-ola-700 hover:underline">Entry</Link>}
                    {j.status === "pending" && canMj && j.created_by !== mine && (
                      <>
                        <ReasonDialog trigger="Approve" triggerVariant="primary" title={`Approve ${j.draft_no}`} description="It is posted to the ledger straight away." reasonRequired={false}
                          confirmLabel="Approve & post" action={decideJournal} hidden={{ draft_id: j.id, decision: "approve" }} />
                        <ReasonDialog trigger="Reject" triggerVariant="dangerOutline" title={`Reject ${j.draft_no}`} confirmLabel="Reject" confirmVariant="danger"
                          action={decideJournal} hidden={{ draft_id: j.id, decision: "reject" }} />
                      </>
                    )}
                    {j.status === "pending" && j.created_by === mine && (
                      <ReasonDialog trigger="Withdraw" triggerVariant="ghost" title={`Withdraw ${j.draft_no}`} reasonRequired={false} confirmLabel="Withdraw"
                        action={decideJournal} hidden={{ draft_id: j.id, decision: "withdraw" }} />
                    )}
                  </span>
                </div>
                <p className="text-muted">Why: {j.reason}{j.decision_note && ` · Decision: ${j.decision_note}`}</p>
                {j.status === "pending" && (
                  <table className="mt-2 w-full max-w-2xl text-xs">
                    <tbody>{j.lines.map((l, i) => <tr key={i}><td className="py-0.5">{acc[l.account_id] ?? l.account_id}{l.memo && <span className="text-muted"> — {l.memo}</span>}</td>
                      <td className="num text-right">{Number(l.debit) ? formatLKR(l.debit) : ""}</td><td className="num text-right">{Number(l.credit) ? formatLKR(l.credit) : ""}</td></tr>)}</tbody>
                  </table>
                )}
              </div>
            ))}
          </div>
        </Card>
      )}

      {can(access, "accounting.view") && (
        <>
          <Card className="mb-4 p-4">
            <form className="flex flex-wrap items-end gap-3" method="get">
              <div><Label htmlFor="from">From</Label><Input id="from" name="from" type="date" defaultValue={from} /></div>
              <div><Label htmlFor="to">To</Label><Input id="to" name="to" type="date" defaultValue={to} /></div>
              <div><Label htmlFor="q">Search</Label><Input id="q" name="q" defaultValue={sp.q ?? ""} placeholder="Entry no. or description" /></div>
              <Button type="submit"><Search className="h-4 w-4" /> Show</Button>
            </form>
          </Card>
          <Card>
            <Table>
              <thead><tr><Th>Entry</Th><Th>Date</Th><Th>Type</Th><Th>Description</Th><Th className="text-right">Amount</Th></tr></thead>
              <tbody>{(entries ?? []).map((e) => (
                <tr key={e.id} className="hover:bg-ola-50/40">
                  <Td><Link href={`/accounting/journals/${e.id}`} className="font-mono text-xs text-ola-700 hover:underline">{e.entry_no}</Link></Td>
                  <Td className="whitespace-nowrap">{formatDate(e.entry_date)}</Td>
                  <Td className="text-xs">{humanize(e.event_type.replace(/\./g, " "))}{e.reverses_entry_id && <Badge tone="amber" className="ml-1">Reversal</Badge>}</Td>
                  <Td className="max-w-lg">{e.description}</Td>
                  <Td className="num text-right">{formatLKR(e.total)}</Td>
                </tr>
              ))}</tbody>
            </Table>
            {(entries ?? []).length === 200 && <p className="px-5 py-3 text-xs text-muted">Showing the latest 200 — narrow the dates to see more. {formatDateTime(new Date())}</p>}
          </Card>
        </>
      )}
    </>
  );
}
