import type { Metadata } from "next";
import Link from "next/link";
import { ArrowLeft, Download } from "lucide-react";
import { requirePermission, can } from "@/lib/access";
import { createClient } from "@/lib/supabase/server";
import { isUuid } from "@/lib/actions";
import { formatDate, formatLKR, todayISO } from "@/lib/format";
import { PageHeader } from "@/components/ui/page-header";
import { Card, CardHeader } from "@/components/ui/card";
import { Table, Td, Th } from "@/components/ui/table";
import { Alert } from "@/components/ui/alert";
import { Button, buttonVariants } from "@/components/ui/button";
import { Input, Label, Select } from "@/components/ui/field";

export const metadata: Metadata = { title: "General ledger" };

type Ledger = { account: { code: string; name: string }; opening: number; closing: number; debit: number; credit: number;
  lines: { entry_id: string; entry_no: string; date: string; description: string; memo: string | null; party: string | null; debit: number; credit: number; balance: number }[] };

export default async function LedgerPage({ searchParams }: { searchParams: Promise<{ account?: string; from?: string; to?: string }> }) {
  const access = await requirePermission("accounting.view");
  const sp = await searchParams;
  const today = todayISO();
  const to = sp.to && /^\d{4}-\d{2}-\d{2}$/.test(sp.to) ? sp.to : today;
  const from = sp.from && /^\d{4}-\d{2}-\d{2}$/.test(sp.from) ? sp.from : `${to.slice(0, 8)}01`;
  const supabase = await createClient();
  const { data: accounts } = await supabase.from("accounts").select("id, code, name, is_postable").eq("is_postable", true).order("code");
  const account = sp.account && isUuid(sp.account) ? sp.account : accounts?.find((a) => a.code === "1200")?.id ?? accounts?.[0]?.id;
  const { data, error } = account ? await supabase.rpc("report_general_ledger", { p_account: account, p_from: from, p_to: to }) : { data: null, error: null };
  const d = data as Ledger | null;

  return (
    <>
      <Link href="/accounting" className="no-print mb-3 inline-flex items-center gap-1 text-sm text-ola-700 hover:underline"><ArrowLeft className="h-4 w-4" /> Accounting</Link>
      <PageHeader title="General ledger" description="Every posting to one account, with a running balance (debit +, credit −). Click an entry to see where it came from."
        actions={can(access, "reports.export") && account && <a className={buttonVariants({ variant: "secondary", size: "md" })} href={`/accounting/export/ledger?account=${account}&from=${from}&to=${to}`}><Download className="h-4 w-4" /> Excel (CSV)</a>} />
      <Card className="no-print mb-4 p-4">
        <form className="flex flex-wrap items-end gap-3" method="get">
          <div className="min-w-72"><Label htmlFor="account">Account</Label>
            <Select id="account" name="account" defaultValue={account}>{accounts?.map((a) => <option key={a.id} value={a.id}>{a.code} {a.name}</option>)}</Select></div>
          <div><Label htmlFor="from">From</Label><Input id="from" name="from" type="date" defaultValue={from} /></div>
          <div><Label htmlFor="to">To</Label><Input id="to" name="to" type="date" defaultValue={to} /></div>
          <Button type="submit">Show</Button>
        </form>
      </Card>
      {error && <Alert tone="error">{error.message}</Alert>}
      {d && (
        <Card>
          <CardHeader title={`${d.account.code} ${d.account.name}`} description={`${formatDate(from)} – ${formatDate(to)}`} />
          <Table>
            <thead><tr><Th>Date</Th><Th>Entry</Th><Th>Details</Th><Th className="text-right">Debit</Th><Th className="text-right">Credit</Th><Th className="text-right">Balance</Th></tr></thead>
            <tbody>
              <tr><Td /><Td /><Td className="font-medium">Opening balance</Td><Td /><Td /><Td className="num text-right font-medium">{formatLKR(d.opening)}</Td></tr>
              {d.lines.map((l, i) => (
                <tr key={i}>
                  <Td className="whitespace-nowrap">{formatDate(l.date)}</Td>
                  <Td><Link href={`/accounting/journals/${l.entry_id}`} className="font-mono text-xs text-ola-700 hover:underline">{l.entry_no}</Link></Td>
                  <Td className="max-w-md">{l.description}{(l.memo || l.party) && <span className="block text-xs text-muted">{[l.memo, l.party].filter(Boolean).join(" · ")}</span>}</Td>
                  <Td className="num text-right">{Number(l.debit) ? formatLKR(l.debit) : ""}</Td>
                  <Td className="num text-right">{Number(l.credit) ? formatLKR(l.credit) : ""}</Td>
                  <Td className={`num text-right ${Number(l.balance) < 0 ? "text-red-700" : ""}`}>{formatLKR(l.balance)}</Td>
                </tr>
              ))}
              <tr className="font-semibold"><Td /><Td /><Td>Closing balance</Td><Td className="num text-right">{formatLKR(d.debit)}</Td><Td className="num text-right">{formatLKR(d.credit)}</Td>
                <Td className="num text-right">{formatLKR(d.closing)}</Td></tr>
            </tbody>
          </Table>
        </Card>
      )}
    </>
  );
}
