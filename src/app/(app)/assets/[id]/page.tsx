import type { Metadata } from "next";
import { DocumentsCard } from "@/components/documents/documents-card";
import Link from "next/link";
import { notFound } from "next/navigation";
import { ArrowLeft } from "lucide-react";
import { requirePermission, can } from "@/lib/access";
import { createClient } from "@/lib/supabase/server";
import { isUuid } from "@/lib/actions";
import { formatDate, formatLKR, humanize, todayISO } from "@/lib/format";
import { MONTHS } from "@/lib/labels";
import { PageHeader } from "@/components/ui/page-header";
import { Card, CardBody, CardHeader, Stat } from "@/components/ui/card";
import { Table, Td, Th } from "@/components/ui/table";
import { Badge } from "@/components/ui/badge";
import { Alert } from "@/components/ui/alert";
import { FormDialog } from "@/components/ui/form-dialog";
import { ReasonDialog } from "@/components/ui/reason-dialog";
import { Field, Input, Select, Textarea } from "@/components/ui/field";
import { MethodFields } from "../../expenses/method-fields";
import { disposeAsset, recordMaintenance, updateAsset } from "../actions";

export const metadata: Metadata = { title: "Fixed asset" };

type Details = {
  asset: { id: string; asset_no: string; name: string; category: string; serial_no: string | null; description: string | null; location_id: string | null; location: string | null;
    responsible_employee_id: string | null; responsible: string | null; supplier_name: string | null; purchase_date: string; cost: number; residual_value: number;
    method: string; useful_life_months: number | null; rate_percent: number | null; depreciation_start: string; accumulated: number; opening_accumulated: number;
    book_value: number; monthly: number; warranty_until: string | null; funding: string; status: string; disposed_on: string | null; disposal_proceeds: number | null;
    disposal_note: string | null; vehicle: { id: string; registration_no: string } | null };
  depreciation: { year: number; month: number; amount: number }[];
  maintenance: { expense_no: string; date: string; description: string; total: number; status: string }[];
  journals: { id: string; entry_no: string; entry_date: string; event_type: string; total: number }[];
};

export default async function AssetPage({ params }: { params: Promise<{ id: string }> }) {
  const access = await requirePermission(["assets.manage", "accounting.view"]);
  const { id } = await params;
  if (!isUuid(id)) notFound();
  const supabase = await createClient();
  const [{ data, error }, { data: locations }, { data: staff }, { data: money }] = await Promise.all([
    supabase.rpc("asset_details", { p_asset: id }),
    supabase.from("locations").select("id, name").eq("is_active", true).neq("location_type", "virtual").order("name"),
    supabase.rpc("employee_directory"),
    supabase.from("money_accounts").select("id, name, kind").eq("is_active", true).order("is_default", { ascending: false }),
  ]);
  if (error || !data) notFound();
  const d = data as Details;
  const a = d.asset;
  const manage = can(access, "assets.manage") && a.status === "active";
  const today = todayISO();
  const people = ((staff ?? []) as { id: string; full_name: string; status: string }[]).filter((s) => s.status === "active");
  const hidden = { asset_id: a.id };

  return (
    <>
      <Link href="/assets" className="mb-3 inline-flex items-center gap-1 text-sm text-ola-700 hover:underline"><ArrowLeft className="h-4 w-4" /> Fixed Assets</Link>
      <PageHeader title={a.name} description={[a.asset_no, a.category, a.serial_no && `S/N ${a.serial_no}`, a.location, a.responsible].filter(Boolean).join(" · ")}
        actions={manage && <>
          <FormDialog trigger="Maintenance / repair" triggerVariant="primary" triggerSize="md" title={`Maintenance — ${a.name}`} description="Recorded as an expense linked to this asset."
            submitLabel="Save" action={recordMaintenance} hidden={hidden}>
            <div className="grid gap-4 sm:grid-cols-3">
              <Field label="Date" htmlFor="am-d"><Input id="am-d" name="date" type="date" defaultValue={today} max={today} /></Field>
              <Field label="Cost before VAT (Rs.)" htmlFor="am-c" required><Input id="am-c" name="cost" type="number" min={0.01} step="0.01" required /></Field>
              <Field label="VAT (Rs.)" htmlFor="am-v"><Input id="am-v" name="vat_amount" type="number" min={0} step="0.01" /></Field>
            </div>
            <Field label="Work done" htmlFor="am-w" required><Input id="am-w" name="description" required placeholder="e.g. RO membrane replaced" /></Field>
            <Field label="Done by" htmlFor="am-b"><Input id="am-b" name="vendor" /></Field>
            <MethodFields accounts={money ?? []} prefix="am" />
          </FormDialog>
          <FormDialog trigger="Edit" triggerSize="md" title={`Edit ${a.name}`} description="Cost and depreciation settings cannot be changed once registered." submitLabel="Save"
            action={updateAsset} hidden={hidden}>
            <Field label="Name" htmlFor="ae-n"><Input id="ae-n" name="name" defaultValue={a.name} /></Field>
            <div className="grid gap-4 sm:grid-cols-2">
              <Field label="Serial no." htmlFor="ae-s"><Input id="ae-s" name="serial_no" defaultValue={a.serial_no ?? ""} /></Field>
              <Field label="Supplier" htmlFor="ae-su"><Input id="ae-su" name="supplier_name" defaultValue={a.supplier_name ?? ""} /></Field>
              <Field label="Location" htmlFor="ae-l"><Select id="ae-l" name="location_id" defaultValue={a.location_id ?? ""}><option value="">—</option>
                {locations?.map((l) => <option key={l.id} value={l.id}>{l.name}</option>)}</Select></Field>
              <Field label="Responsible person" htmlFor="ae-r"><Select id="ae-r" name="responsible_employee_id" defaultValue={a.responsible_employee_id ?? ""}><option value="">—</option>
                {people.map((p) => <option key={p.id} value={p.id}>{p.full_name}</option>)}</Select></Field>
              <Field label="Warranty until" htmlFor="ae-w"><Input id="ae-w" name="warranty_until" type="date" defaultValue={a.warranty_until ?? ""} /></Field>
            </div>
            <Field label="Description" htmlFor="ae-d"><Textarea id="ae-d" name="description" defaultValue={a.description ?? ""} /></Field>
            <Field label="Reason for change" htmlFor="ae-rs"><Input id="ae-rs" name="reason" /></Field>
          </FormDialog>
          <ReasonDialog trigger="Dispose / sell" triggerVariant="dangerOutline" title={`Dispose of ${a.name}`}
            description={`Book value ${formatLKR(a.book_value)}. Run depreciation up to the month of disposal first.`} confirmLabel="Dispose" confirmVariant="danger"
            action={disposeAsset} hidden={hidden}>
            <div className="grid gap-4 sm:grid-cols-2">
              <Field label="Date" htmlFor="ad-d"><Input id="ad-d" name="disposed_on" type="date" defaultValue={today} max={today} /></Field>
              <Field label="Sold for (Rs.)" htmlFor="ad-p" hint="0 if scrapped"><Input id="ad-p" name="proceeds" type="number" min={0} step="0.01" defaultValue={0} /></Field>
            </div>
            <Field label="Money received into" htmlFor="ad-m"><Select id="ad-m" name="money_account_id"><option value="">Nothing received</option>
              {money?.filter((m) => m.kind !== "card_clearing").map((m) => <option key={m.id} value={m.id}>{m.name}</option>)}</Select></Field>
          </ReasonDialog>
        </>} />

      {a.status !== "active" && <Alert tone="info" className="mb-4">Disposed {a.disposed_on ? formatDate(a.disposed_on) : ""} for {formatLKR(a.disposal_proceeds)} — {a.disposal_note}</Alert>}
      {a.vehicle && <p className="mb-4 text-sm">Vehicle: <Link href={`/fleet/${a.vehicle.id}`} className="text-ola-700 hover:underline">{a.vehicle.registration_no}</Link></p>}

      <div className="mb-6 grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <Stat label="Cost" value={formatLKR(a.cost)} hint={`Bought ${formatDate(a.purchase_date)}${a.supplier_name ? ` from ${a.supplier_name}` : ""}`} />
        <Stat label="Depreciation to date" value={formatLKR(a.accumulated)} hint={Number(a.opening_accumulated) > 0 ? `incl. ${formatLKR(a.opening_accumulated)} before go-live` : undefined} />
        <Stat label="Book value" value={formatLKR(a.book_value)} hint={`Residual ${formatLKR(a.residual_value)}`} />
        <Stat label="Depreciation a month" value={formatLKR(a.monthly)}
          hint={a.method === "straight_line" ? `Straight line over ${Number(a.useful_life_months) / 12} years` : `Reducing balance ${a.rate_percent}% a year`} />
      </div>

      <div className="grid gap-6 lg:grid-cols-2">
        <Card>
          <CardHeader title="Depreciation history" />
          {d.depreciation.length === 0 ? <CardBody><p className="text-sm text-muted">Not depreciated yet (starts {formatDate(a.depreciation_start)}).</p></CardBody> : (
            <Table>
              <thead><tr><Th>Month</Th><Th className="text-right">Amount</Th></tr></thead>
              <tbody>{d.depreciation.map((x) => <tr key={`${x.year}-${x.month}`}><Td>{MONTHS[x.month - 1]} {x.year}</Td><Td className="num text-right">{formatLKR(x.amount)}</Td></tr>)}</tbody>
            </Table>
          )}
        </Card>
        <Card>
          <CardHeader title="Maintenance & repairs" />
          {d.maintenance.length === 0 ? <CardBody><p className="text-sm text-muted">None recorded.</p></CardBody> : (
            <Table>
              <thead><tr><Th>Date</Th><Th>Work</Th><Th className="text-right">Cost</Th></tr></thead>
              <tbody>{d.maintenance.map((x) => (
                <tr key={x.expense_no}><Td className="whitespace-nowrap">{formatDate(x.date)}</Td><Td>{x.description}<span className="block text-xs text-muted">{x.expense_no}</span></Td>
                  <Td className="num text-right">{formatLKR(x.total)}{x.status === "pending_approval" && <Badge tone="amber" className="ml-1">Waiting</Badge>}</Td></tr>))}</tbody>
            </Table>
          )}
        </Card>
        {d.journals.length > 0 && (
          <Card className="lg:col-span-2">
            <CardHeader title="Accounting entries" />
            <Table>
              <thead><tr><Th>Entry</Th><Th>Date</Th><Th>Type</Th><Th className="text-right">Amount</Th></tr></thead>
              <tbody>{d.journals.map((j) => (
                <tr key={j.id}><Td><Link href={`/accounting/journals/${j.id}`} className="font-mono text-xs text-ola-700 hover:underline">{j.entry_no}</Link></Td>
                  <Td>{formatDate(j.entry_date)}</Td><Td>{humanize(j.event_type.replace(".", " "))}</Td><Td className="num text-right">{formatLKR(j.total)}</Td></tr>))}</tbody>
            </Table>
          </Card>
        )}
      </div>
      <div className="mt-6"><DocumentsCard access={access} entityType="asset" entityId={id} categories={["contract","insurance","other"]} returnTo={`/assets/${id}`} /></div>
    </>
  );
}
