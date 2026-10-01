import type { Metadata } from "next";
import Link from "next/link";
import { notFound } from "next/navigation";
import { ArrowLeft } from "lucide-react";
import { requirePermission, can } from "@/lib/access";
import { createClient } from "@/lib/supabase/server";
import { isUuid } from "@/lib/actions";
import { formatDate, formatDateTime, formatLKR, humanize, todayISO } from "@/lib/format";
import { PageHeader } from "@/components/ui/page-header";
import { Card } from "@/components/ui/card";
import { Table, Td, Th } from "@/components/ui/table";
import { Alert } from "@/components/ui/alert";
import { ReasonDialog } from "@/components/ui/reason-dialog";
import { Field, Input } from "@/components/ui/field";
import { reverseEntry } from "../../actions";

export const metadata: Metadata = { title: "Journal entry" };

type D = {
  entry: { id: string; entry_no: string; entry_date: string; event_type: string; description: string; total: number; source_type: string | null; source_id: string | null;
    created_at: string; created_by_name: string | null; period: string; location: string | null };
  lines: { line_no: number; account_id: string; code: string; name: string; debit: number; credit: number; memo: string | null; party: string | null }[];
  reverses: { id: string; entry_no: string } | null; reversed_by: { id: string; entry_no: string; entry_date: string } | null; reason: string | null;
};

const SOURCE: Record<string, (id: string) => string> = {
  production_batch: (id) => `/production/${id}`,
  goods_receipt: () => "/purchasing",
  supplier_invoice: () => "/purchasing",
  expense: () => "/expenses",
};

export default async function EntryPage({ params }: { params: Promise<{ id: string }> }) {
  const access = await requirePermission("accounting.view");
  const { id } = await params;
  if (!isUuid(id)) notFound();
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("journal_entry_details", { p_entry: id });
  if (error || !data) notFound();
  const d = data as D;
  const e = d.entry;
  const src = e.source_type && e.source_id && SOURCE[e.source_type] ? SOURCE[e.source_type](e.source_id) : null;

  return (
    <>
      <Link href="/accounting/journals" className="mb-3 inline-flex items-center gap-1 text-sm text-ola-700 hover:underline"><ArrowLeft className="h-4 w-4" /> Journals</Link>
      <PageHeader title={`Entry ${e.entry_no}`} description={`${formatDate(e.entry_date)} · ${e.period} · ${humanize(e.event_type.replace(/\./g, " "))} · posted ${formatDateTime(e.created_at)} by ${e.created_by_name ?? "the system"}`}
        actions={can(access, "accounting.reverse") && !d.reverses && !d.reversed_by && (
          <ReasonDialog trigger="Reverse entry" triggerVariant="dangerOutline" triggerSize="md" title={`Reverse ${e.entry_no}`}
            description="Posts the opposite entry. Use the screen the entry came from where there is one (e.g. reverse a payment from the customer page) so the documents stay in step."
            confirmLabel="Reverse" confirmVariant="danger" action={reverseEntry} hidden={{ entry_id: e.id }}>
            <Field label="Reversal date" htmlFor="rv-d" hint="Must be in an open month"><Input id="rv-d" name="reversal_date" type="date" defaultValue={todayISO()} /></Field>
          </ReasonDialog>
        )} />
      <p className="mb-4 text-sm">{e.description}{e.location && <span className="text-muted"> · {e.location}</span>}</p>
      {d.reason && <Alert tone="info" className="mb-4">Reason recorded: {d.reason}</Alert>}
      {d.reverses && <Alert tone="warning" className="mb-4">This entry reverses <Link href={`/accounting/journals/${d.reverses.id}`} className="font-semibold underline">{d.reverses.entry_no}</Link>.</Alert>}
      {d.reversed_by && <Alert tone="warning" className="mb-4">Reversed by <Link href={`/accounting/journals/${d.reversed_by.id}`} className="font-semibold underline">{d.reversed_by.entry_no}</Link> on {formatDate(d.reversed_by.entry_date)}.</Alert>}
      {src && <p className="mb-4 text-sm"><Link href={src} className="text-ola-700 hover:underline">Open the source document →</Link></p>}
      <Card>
        <Table>
          <thead><tr><Th>#</Th><Th>Account</Th><Th>Note</Th><Th className="text-right">Debit</Th><Th className="text-right">Credit</Th></tr></thead>
          <tbody>
            {d.lines.map((l) => (
              <tr key={l.line_no}><Td>{l.line_no}</Td>
                <Td><Link href={`/accounting/ledger?account=${l.account_id}&from=${e.entry_date}&to=${e.entry_date}`} className="hover:underline">{l.code} {l.name}</Link></Td>
                <Td>{l.memo}{l.party && <span className="block text-xs text-muted">{l.party}</span>}</Td>
                <Td className="num text-right">{Number(l.debit) ? formatLKR(l.debit) : ""}</Td><Td className="num text-right">{Number(l.credit) ? formatLKR(l.credit) : ""}</Td></tr>
            ))}
            <tr className="font-semibold"><Td /><Td>Total</Td><Td /><Td className="num text-right">{formatLKR(e.total)}</Td><Td className="num text-right">{formatLKR(e.total)}</Td></tr>
          </tbody>
        </Table>
      </Card>
    </>
  );
}
