import type { Metadata } from "next";
import Link from "next/link";
import { ArrowLeft, Plus } from "lucide-react";
import { requirePermission, can } from "@/lib/access";
import { createClient } from "@/lib/supabase/server";
import { formatDate, formatDateTime, formatLKR, todayISO } from "@/lib/format";
import { PageHeader } from "@/components/ui/page-header";
import { Card, CardHeader } from "@/components/ui/card";
import { Table, Td, Th } from "@/components/ui/table";
import { Badge } from "@/components/ui/badge";
import { ActionForm } from "@/components/ui/action-form";
import { SubmitButton } from "@/components/ui/submit-button";
import { FormDialog } from "@/components/ui/form-dialog";
import { ReasonDialog } from "@/components/ui/reason-dialog";
import { Field, Input, Select } from "@/components/ui/field";
import { buttonVariants } from "@/components/ui/button";
import { clearCheque, depositCheques, fundTransfer, returnCheque, saveMoneyAccount } from "../actions";

export const metadata: Metadata = { title: "Banking & cheques" };

type Money = { id: string; name: string; kind: string; code: string; bank_name: string | null; account_no: string | null; balance: number;
  last_reconciled: string | null; is_active: boolean; is_default: boolean };
type Cheque = { id: string; payment_no: string; customer_id: string; customer: string; amount: number; reference: string | null; received_at: string;
  cheque_status: string; deposited_at: string | null; deposited_to: string | null; cleared_at: string | null; returned_at: string | null; reversal_reason: string | null };
const KIND: Record<string, string> = { cash: "Cash", petty_cash: "Petty cash", bank: "Bank", card_clearing: "Card / QR clearing" };

export default async function BankingPage() {
  const access = await requirePermission(["payments.manage", "accounting.view"]);
  const supabase = await createClient();
  const [{ data: ov }, { data: cheques }, { data: transfers }] = await Promise.all([
    supabase.rpc("accounting_overview"),
    supabase.rpc("cheque_register", { p_status: null }),
    supabase.from("fund_transfers").select("id, transfer_no, kind, amount, fee, transfer_date, reference, from:money_accounts!fund_transfers_from_account_id_fkey(name), to:money_accounts!fund_transfers_to_account_id_fkey(name)")
      .order("created_at", { ascending: false }).limit(20),
  ]);
  const money = ((ov as { money: Money[] } | null)?.money ?? []);
  const active = money.filter((m) => m.is_active);
  const banks = active.filter((m) => m.kind === "bank");
  const list = (cheques ?? []) as Cheque[];
  const inHand = list.filter((c) => c.cheque_status === "in_hand");
  const deposited = list.filter((c) => c.cheque_status === "deposited");
  const other = list.filter((c) => c.cheque_status === "cleared" || c.cheque_status === "returned").slice(0, 20);
  const manage = can(access, "payments.manage");
  const today = todayISO();
  const opts = (xs: Money[]) => xs.map((m) => <option key={m.id} value={m.id}>{m.name}</option>);

  return (
    <>
      <Link href="/accounting" className="mb-3 inline-flex items-center gap-1 text-sm text-ola-700 hover:underline"><ArrowLeft className="h-4 w-4" /> Accounting</Link>
      <PageHeader title="Banking & cheques" description="Cash and bank accounts, moving money between them, card settlements, cheques received and bank reconciliation."
        actions={manage && <>
          <FormDialog trigger="Transfer money" triggerVariant="primary" triggerSize="md" title="Move money between accounts"
            description="Cash banked, petty cash top-up, bank to bank." submitLabel="Record transfer" action={fundTransfer} hidden={{ kind: "transfer" }}>
            <div className="grid gap-4 sm:grid-cols-2">
              <Field label="From" htmlFor="tf-f"><Select id="tf-f" name="from_account_id">{opts(active.filter((m) => m.kind !== "card_clearing"))}</Select></Field>
              <Field label="To" htmlFor="tf-t"><Select id="tf-t" name="to_account_id" defaultValue={banks[0]?.id}>{opts(active.filter((m) => m.kind !== "card_clearing"))}</Select></Field>
              <Field label="Amount (Rs.)" htmlFor="tf-a" required><Input id="tf-a" name="amount" type="number" min={0.01} step="0.01" required /></Field>
              <Field label="Bank charge (Rs.)" htmlFor="tf-fee"><Input id="tf-fee" name="fee" type="number" min={0} step="0.01" defaultValue={0} /></Field>
              <Field label="Date" htmlFor="tf-d"><Input id="tf-d" name="date" type="date" defaultValue={today} /></Field>
              <Field label="Reference" htmlFor="tf-r" hint="Deposit slip / transfer no."><Input id="tf-r" name="reference" /></Field>
            </div>
          </FormDialog>
          <FormDialog trigger="Card settlement" triggerSize="md" title="Card / QR money received by the bank"
            description="Enter the sales total the bank settled and the commission it kept." submitLabel="Record" action={fundTransfer} hidden={{ kind: "card_settlement" }}>
            <div className="grid gap-4 sm:grid-cols-2">
              <Field label="Into bank" htmlFor="cs-t"><Select id="cs-t" name="to_account_id">{opts(banks)}</Select></Field>
              <Field label="Date" htmlFor="cs-d"><Input id="cs-d" name="date" type="date" defaultValue={today} /></Field>
              <Field label="Sales settled (Rs.)" htmlFor="cs-a" required><Input id="cs-a" name="amount" type="number" min={0.01} step="0.01" required /></Field>
              <Field label="Commission kept (Rs.)" htmlFor="cs-f"><Input id="cs-f" name="fee" type="number" min={0} step="0.01" defaultValue={0} /></Field>
            </div>
            <Field label="Settlement reference" htmlFor="cs-r"><Input id="cs-r" name="reference" /></Field>
          </FormDialog>
          <FormDialog trigger="Bank charge / interest" triggerSize="md" title="Bank charge or interest on the statement" submitLabel="Record" action={fundTransfer}>
            <Field label="What" htmlFor="bc-k"><Select id="bc-k" name="kind"><option value="bank_charge">Bank charge</option><option value="bank_interest">Interest received</option></Select></Field>
            <div className="grid gap-4 sm:grid-cols-2">
              <Field label="Bank account" htmlFor="bc-a"><Select id="bc-a" name="from_account_id">{opts(banks)}</Select></Field>
              <Field label="Amount (Rs.)" htmlFor="bc-amt" required><Input id="bc-amt" name="amount" type="number" min={0.01} step="0.01" required /></Field>
              <Field label="Date" htmlFor="bc-d"><Input id="bc-d" name="date" type="date" defaultValue={today} /></Field>
              <Field label="Reference" htmlFor="bc-r"><Input id="bc-r" name="reference" /></Field>
            </div>
            <p className="text-xs text-muted">Interest is added to the chosen bank account; a charge is taken from it.</p>
          </FormDialog>
        </>} />

      <div className="space-y-6">
        <Card>
          <CardHeader title="Cash and bank accounts" actions={can(access, "accounting.period_close") && (
            <FormDialog trigger={<><Plus className="h-4 w-4" /> Add account</>} title="Add a bank or cash account" description="It gets its own ledger account." submitLabel="Add" action={saveMoneyAccount}>
              <Field label="Kind" htmlFor="ma-k"><Select id="ma-k" name="kind"><option value="bank">Bank account</option><option value="petty_cash">Petty cash box</option><option value="cash">Cash drawer</option></Select></Field>
              <Field label="Name" htmlFor="ma-n" required><Input id="ma-n" name="name" required placeholder="e.g. Sampath current" /></Field>
              <div className="grid gap-4 sm:grid-cols-3">
                <Field label="Bank" htmlFor="ma-b"><Input id="ma-b" name="bank_name" /></Field>
                <Field label="Branch" htmlFor="ma-br"><Input id="ma-br" name="branch" /></Field>
                <Field label="Account no." htmlFor="ma-no"><Input id="ma-no" name="account_no" /></Field>
              </div>
            </FormDialog>
          )} />
          <Table>
            <thead><tr><Th>Account</Th><Th>Kind</Th><Th className="text-right">Balance in the books</Th><Th>Reconciled to</Th><Th /></tr></thead>
            <tbody>{money.map((m) => (
              <tr key={m.id} className={m.is_active ? "" : "opacity-50"}>
                <Td><span className="font-medium">{m.name}</span><span className="block text-xs text-muted">{m.code}{m.bank_name && ` · ${m.bank_name}`}{m.account_no && ` · ${m.account_no}`}</span></Td>
                <Td>{KIND[m.kind]}{m.is_default && <Badge tone="blue" className="ml-2">Default</Badge>}</Td>
                <Td className={`num text-right ${Number(m.balance) < 0 ? "text-red-700" : ""}`}>{formatLKR(m.balance)}</Td>
                <Td>{m.kind === "bank" ? (m.last_reconciled ? formatDate(m.last_reconciled) : <span className="text-amber-700">Never</span>) : "—"}</Td>
                <Td className="text-right">{m.kind === "bank" && m.is_active && manage && <Link href={`/accounting/banking/reconcile/${m.id}`} className={buttonVariants({ variant: "secondary", size: "sm" })}>Reconcile</Link>}</Td>
              </tr>
            ))}</tbody>
          </Table>
        </Card>

        <Card>
          <CardHeader title="Cheques in hand" description="Cheques received from customers that have not been banked yet. Tick the ones on today's deposit slip." />
          {inHand.length === 0 ? <p className="px-5 py-4 text-sm text-muted">No cheques in hand.</p> : manage ? (
            <ActionForm action={depositCheques} className="p-5">
              <table className="w-full text-sm">
                <thead className="text-left text-xs text-muted"><tr><th className="w-8" /><th className="py-1">Cheque</th><th>Customer</th><th>Received</th><th className="text-right">Amount</th><th /></tr></thead>
                <tbody>{inHand.map((c) => (
                  <tr key={c.id} className="border-t border-line">
                    <td className="py-2"><input type="checkbox" name="cheque" value={c.id} aria-label={`Deposit ${c.payment_no}`} defaultChecked /></td>
                    <td>{c.reference}<span className="block text-xs text-muted">{c.payment_no}</span></td>
                    <td><Link href={`/customers/${c.customer_id}`} className="text-ola-700 hover:underline">{c.customer}</Link></td>
                    <td>{formatDateTime(c.received_at)}</td>
                    <td className="num text-right">{formatLKR(c.amount)}</td>
                    <td />
                  </tr>
                ))}</tbody>
              </table>
              <div className="grid gap-4 sm:grid-cols-3">
                <Field label="Deposit into" htmlFor="dc-b"><Select id="dc-b" name="money_account_id">{opts(banks)}</Select></Field>
                <Field label="Deposit slip no." htmlFor="dc-r"><Input id="dc-r" name="reference" /></Field>
                <div className="flex items-end"><SubmitButton>Deposit ticked cheques</SubmitButton></div>
              </div>
            </ActionForm>
          ) : (
            <Table><tbody>{inHand.map((c) => <tr key={c.id}><Td>{c.reference}</Td><Td>{c.customer}</Td><Td className="num text-right">{formatLKR(c.amount)}</Td></tr>)}</tbody></Table>
          )}
        </Card>

        <Card>
          <CardHeader title="Cheques banked, waiting to clear" description="Mark them cleared when they appear on the statement, or returned if the bank sends them back." />
          {deposited.length === 0 ? <p className="px-5 py-4 text-sm text-muted">Nothing waiting.</p> : (
            <Table>
              <thead><tr><Th>Cheque</Th><Th>Customer</Th><Th>Banked</Th><Th className="text-right">Amount</Th><Th /></tr></thead>
              <tbody>{deposited.map((c) => (
                <tr key={c.id}><Td>{c.reference}<span className="block text-xs text-muted">{c.payment_no}</span></Td>
                  <Td><Link href={`/customers/${c.customer_id}`} className="text-ola-700 hover:underline">{c.customer}</Link></Td>
                  <Td>{c.deposited_at ? formatDate(c.deposited_at) : ""}<span className="block text-xs text-muted">{c.deposited_to}</span></Td>
                  <Td className="num text-right">{formatLKR(c.amount)}</Td>
                  <Td className="space-x-1 whitespace-nowrap text-right">{manage && <>
                    <FormDialog trigger="Cleared" title={`Cheque ${c.reference} cleared`} submitLabel="Mark cleared" action={clearCheque} hidden={{ payment_id: c.id }}>
                      <p className="text-sm">The money is on the bank statement.</p></FormDialog>
                    <ReasonDialog trigger="Returned" triggerVariant="dangerOutline" title={`Cheque ${c.reference} returned`}
                      description="The bank sent it back. The customer will owe the amount again and the invoices it paid become unpaid." confirmLabel="Record return"
                      confirmVariant="danger" action={returnCheque} hidden={{ payment_id: c.id }} />
                  </>}</Td>
                </tr>
              ))}</tbody>
            </Table>
          )}
          {inHand.length > 0 && manage && <p className="px-5 py-3 text-xs text-muted">A cheque still in hand that bounces before banking can be recorded as returned from the customer&apos;s page (Reverse).</p>}
        </Card>

        <div className="grid gap-6 lg:grid-cols-2">
          <Card>
            <CardHeader title="Recent transfers" />
            {(transfers ?? []).length === 0 ? <p className="px-5 py-4 text-sm text-muted">None yet.</p> : (
              <Table><tbody>{(transfers as unknown as { id: string; transfer_no: string; kind: string; amount: number; fee: number; transfer_date: string; reference: string | null;
                from: { name: string } | null; to: { name: string } | null }[]).map((t) => (
                <tr key={t.id}><Td className="font-mono text-xs">{t.transfer_no}<span className="block font-sans text-muted">{formatDate(t.transfer_date)}</span></Td>
                  <Td>{t.kind === "transfer" ? `${t.from?.name} → ${t.to?.name}` : t.kind === "card_settlement" ? `Card settlement → ${t.to?.name}` : t.kind === "bank_charge" ? `Bank charge — ${t.from?.name}` : `Interest — ${t.to?.name}`}
                    {t.reference && <span className="block text-xs text-muted">{t.reference}</span>}</Td>
                  <Td className="num text-right">{formatLKR(t.amount)}{Number(t.fee) > 0 && <span className="block text-xs text-muted">fee {formatLKR(t.fee)}</span>}</Td></tr>))}</tbody></Table>
            )}
          </Card>
          <Card>
            <CardHeader title="Cleared and returned cheques" />
            {other.length === 0 ? <p className="px-5 py-4 text-sm text-muted">None yet.</p> : (
              <Table><tbody>{other.map((c) => (
                <tr key={c.id}><Td>{c.reference}<span className="block text-xs text-muted">{c.customer}</span></Td>
                  <Td>{c.cheque_status === "returned" ? <Badge tone="red">Returned</Badge> : <Badge tone="green">Cleared</Badge>}
                    {c.reversal_reason && <span className="block text-xs text-muted">{c.reversal_reason}</span>}</Td>
                  <Td className="num text-right">{formatLKR(c.amount)}</Td></tr>))}</tbody></Table>
            )}
          </Card>
        </div>
      </div>
    </>
  );
}
