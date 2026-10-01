import type { Metadata } from "next";
import Link from "next/link";
import { notFound } from "next/navigation";
import { ArrowLeft } from "lucide-react";
import { requirePermission } from "@/lib/access";
import { createClient } from "@/lib/supabase/server";
import { isUuid } from "@/lib/actions";
import { formatDate, formatLKR, todayISO } from "@/lib/format";
import { PageHeader } from "@/components/ui/page-header";
import { Card, CardBody } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Input, Label } from "@/components/ui/field";
import { ReconForm } from "./recon-form";

export const metadata: Metadata = { title: "Bank reconciliation" };

type W = { account: { id: string; name: string; bank_name: string | null; account_no: string | null }; book_balance: number; cleared_balance: number;
  last: { statement_date: string; statement_balance: number } | null;
  items: { line_id: number; date: string; entry_no: string; description: string; memo: string | null; amount: number }[] };

export default async function ReconcilePage({ params, searchParams }: { params: Promise<{ id: string }>; searchParams: Promise<{ date?: string }> }) {
  await requirePermission("payments.manage");
  const { id } = await params;
  if (!isUuid(id)) notFound();
  const sp = await searchParams;
  const date = sp.date && /^\d{4}-\d{2}-\d{2}$/.test(sp.date) ? sp.date : todayISO();
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("bank_reconciliation_workspace", { p_money_account: id, p_statement_date: date });
  if (error || !data) notFound();
  const w = data as W;

  return (
    <>
      <Link href="/accounting/banking" className="mb-3 inline-flex items-center gap-1 text-sm text-ola-700 hover:underline"><ArrowLeft className="h-4 w-4" /> Banking</Link>
      <PageHeader title={`Reconcile ${w.account.name}`}
        description={`Tick each item that appears on the bank statement. Book balance at ${formatDate(date)}: ${formatLKR(w.book_balance)}.${w.last ? ` Last reconciled to ${formatDate(w.last.statement_date)} (${formatLKR(w.last.statement_balance)}).` : ""}`} />
      <Card className="mb-4 p-4">
        <form className="flex flex-wrap items-end gap-3" method="get">
          <div><Label htmlFor="date">Statement date</Label><Input id="date" name="date" type="date" defaultValue={date} /></div>
          <Button type="submit" variant="secondary">Change date</Button>
        </form>
      </Card>
      <Card><CardBody>
        <ReconForm key={date} accountId={w.account.id} statementDate={date} cleared={Number(w.cleared_balance)} items={w.items} />
      </CardBody></Card>
    </>
  );
}
