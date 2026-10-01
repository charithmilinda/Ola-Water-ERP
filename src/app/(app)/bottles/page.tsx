import type { Metadata } from "next";
import { Search } from "lucide-react";
import { requirePermission, can } from "@/lib/access";
import { createClient } from "@/lib/supabase/server";
import { formatDateTime, formatLKR, humanize } from "@/lib/format";
import { PageHeader } from "@/components/ui/page-header";
import { Card, CardBody, CardHeader } from "@/components/ui/card";
import { Table, Td, Th } from "@/components/ui/table";
import { Badge } from "@/components/ui/badge";
import { Alert } from "@/components/ui/alert";
import { FormDialog } from "@/components/ui/form-dialog";
import { ReasonDialog } from "@/components/ui/reason-dialog";
import { Field, Input, Select, Textarea } from "@/components/ui/field";
import { Button } from "@/components/ui/button";
import { registerBottles, openingBottlesAtLocation, markBottle } from "./actions";

export const metadata: Metadata = { title: "Bottles" };

type Overview = { company_id: string; company: string; is_own: boolean; bottle_type: string; holder_kind: string; fill_state: string; qty: number; value: number };
type Details = {
  found: boolean;
  identifier?: { value: string; status: string; entity_type: string } | null;
  bottle?: { code: string; company: string; is_own: boolean; type: string; holder: string; fill_state: string; condition: string; lifecycle: string; fill_count: number; created_at: string };
  history?: { at: string; type: string; from: string; to: string; to_fill: string; by: string | null; reason: string | null }[];
};

const KIND: Record<string, string> = {
  warehouse: "Warehouse", head_office: "Head office", vehicle: "On vehicles", customer: "With customers", water_shop: "Water shops",
  external_holding: "External holding", company: "Returned to owner",
};

export default async function BottlesPage({ searchParams }: { searchParams: Promise<{ code?: string }> }) {
  const access = await requirePermission("bottles.view");
  const { code } = await searchParams;
  const supabase = await createClient();
  const [{ data: overview }, { data: types }, { data: locations }, { data: companies }, details] = await Promise.all([
    supabase.rpc("bottle_overview"),
    supabase.from("bottle_types").select("id, name").eq("is_active", true),
    supabase.from("locations").select("id, name, location_type").eq("is_active", true).in("location_type", ["warehouse", "head_office", "water_shop"]).order("name"),
    supabase.from("bottle_companies").select("id, name, is_own").eq("is_active", true).order("is_own", { ascending: false }),
    code ? supabase.rpc("bottle_details", { p_code: code }) : Promise.resolve({ data: null }),
  ]);
  const rows = (overview ?? []) as Overview[];
  const own = rows.filter((r) => r.is_own);

  const sumKind = (k: string, fill?: string) => own.filter((r) => r.holder_kind === k && (!fill || r.fill_state === fill)).reduce((a, r) => a + Number(r.qty), 0);
  const ownValue = own.filter((r) => r.holder_kind === "customer" || r.holder_kind === "vehicle").reduce((a, r) => a + Number(r.value), 0);
  const d = details.data as Details | null;
  const manage = can(access, "bottles.manage");

  return (
    <>
      <PageHeader title="Bottles" description="Every returnable OLA bottle — in the warehouse, on vehicles and with customers. Tagged bottles have a full history."
        actions={manage && (
          <>
            <FormDialog trigger="Register labelled bottles" triggerSize="md" title="Register labelled bottles" description="Scan the OLA labels you just applied to bottles that are physically at this location." submitLabel="Register" action={registerBottles}>
              <Field label="Location" htmlFor="rb-loc"><Select id="rb-loc" name="location">{locations?.map((l) => <option key={l.id} value={l.id}>{l.name}</option>)}</Select></Field>
              <div className="grid gap-4 sm:grid-cols-2">
                <Field label="Bottle" htmlFor="rb-t"><Select id="rb-t" name="bottle_type_id">{types?.map((t) => <option key={t.id} value={t.id}>{t.name}</option>)}</Select></Field>
                <Field label="State" htmlFor="rb-f"><Select id="rb-f" name="fill"><option value="empty">Empty</option><option value="full">Full</option></Select></Field>
              </div>
              <Field label="Labels" htmlFor="rb-codes" required hint="Scan one after another — each scan adds a new line"><Textarea id="rb-codes" name="codes" rows={6} required className="font-mono" /></Field>
              <Field label="Reason" htmlFor="rb-r"><Input id="rb-r" name="reason" defaultValue="Labels applied" /></Field>
            </FormDialog>
            <FormDialog trigger="Opening balance" triggerSize="md" title="Bottles at a location (go-live)" description="Record bottles counted at a warehouse when the ERP starts." submitLabel="Record" action={openingBottlesAtLocation}>
              <Field label="Location" htmlFor="ob-loc"><Select id="ob-loc" name="location">{locations?.map((l) => <option key={l.id} value={l.id}>{l.name}</option>)}</Select></Field>
              <div className="grid gap-4 sm:grid-cols-2">
                <Field label="Company" htmlFor="ob-co"><Select id="ob-co" name="company_id">{companies?.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}</Select></Field>
                <Field label="Bottle" htmlFor="ob-t"><Select id="ob-t" name="bottle_type_id">{types?.map((t) => <option key={t.id} value={t.id}>{t.name}</option>)}</Select></Field>
                <Field label="State" htmlFor="ob-f"><Select id="ob-f" name="fill"><option value="empty">Empty</option><option value="full">Full</option></Select></Field>
                <Field label="Number of bottles" htmlFor="ob-q" required><Input id="ob-q" name="qty" type="number" min={1} required /></Field>
              </div>
              <Field label="Reason" htmlFor="ob-r" required><Input id="ob-r" name="reason" defaultValue="Go-live count" required /></Field>
            </FormDialog>
          </>
        )} />

      <div className="mb-6 grid gap-4 sm:grid-cols-2 xl:grid-cols-5">
        <Card className="p-5"><p className="text-sm text-muted">Warehouse</p><p className="num mt-2 text-2xl font-semibold">{sumKind("warehouse", "full") + sumKind("head_office", "full")} <span className="text-base font-normal text-muted">full</span></p><p className="text-xs text-muted">{sumKind("warehouse", "empty") + sumKind("head_office", "empty")} empty</p></Card>
        <Card className="p-5"><p className="text-sm text-muted">On vehicles</p><p className="num mt-2 text-2xl font-semibold">{sumKind("vehicle")}</p></Card>
        <Card className="p-5"><p className="text-sm text-muted">With customers</p><p className="num mt-2 text-2xl font-semibold">{sumKind("customer")}</p></Card>
        <Card className="p-5"><p className="text-sm text-muted">Water shops</p><p className="num mt-2 text-2xl font-semibold">{sumKind("water_shop")}</p></Card>
        <Card className="p-5"><p className="text-sm text-muted">Value outside the warehouse</p><p className="num mt-2 text-2xl font-semibold">{formatLKR(ownValue)}</p><p className="text-xs text-muted">At replacement value</p></Card>
      </div>
      {own.some((r) => Number(r.qty) < 0) && <Alert tone="warning" className="mb-6">Some counts are negative — bottles were used before opening balances were entered. Record opening balances to correct this.</Alert>}

      <div className="grid gap-6 xl:grid-cols-2">
        <Card>
          <CardHeader title="Where OLA bottles are" />
          <Table>
            <thead><tr><Th>Bottle</Th><Th>Place</Th><Th>State</Th><Th className="text-right">Count</Th></tr></thead>
            <tbody>
              {own.length === 0 && <tr><Td colSpan={4} className="text-muted">No bottles recorded yet. Start with an opening balance.</Td></tr>}
              {own.map((r, i) => (
                <tr key={i}>
                  <Td>{r.bottle_type}</Td>
                  <Td>{KIND[r.holder_kind] ?? humanize(r.holder_kind)}</Td>
                  <Td className="capitalize">{r.fill_state}</Td>
                  <Td className={`num text-right ${Number(r.qty) < 0 ? "text-red-700" : ""}`}>{Number(r.qty)}</Td>
                </tr>
              ))}
            </tbody>
          </Table>

        </Card>

        <Card>
          <CardHeader title="Look up a bottle" description="Scan or type a label to see where the bottle is and everywhere it has been." />
          <CardBody>
            <form method="get" className="flex gap-2">
              <Input name="code" defaultValue={code} placeholder="OLA-BTL-00001245" className="font-mono" autoFocus={!!code} />
              <Button type="submit"><Search className="h-4 w-4" /> Find</Button>
            </form>
            {code && d && !d.found && (
              <Alert tone="info" className="mt-4">
                {d.identifier ? `Label ${d.identifier.value} exists (${humanize(d.identifier.status)}) but is not on a bottle yet.` : `No bottle or label ${code.toUpperCase()} in the system.`}
              </Alert>
            )}
            {d?.found && d.bottle && (
              <div className="mt-4 space-y-4">
                <div className="flex flex-wrap items-center gap-2">
                  <span className="font-mono text-lg font-semibold">{d.bottle.code}</span>
                  <Badge tone={d.bottle.is_own ? "blue" : "amber"}>{d.bottle.company}</Badge>
                  <Badge tone={d.bottle.lifecycle === "active" ? "green" : "neutral"}>{humanize(d.bottle.lifecycle)}</Badge>
                  {d.bottle.condition !== "good" && <Badge tone="red">{humanize(d.bottle.condition)}</Badge>}
                </div>
                <p className="text-sm">Now: <strong>{d.bottle.holder}</strong> · {d.bottle.fill_state} · {d.bottle.type} · filled {d.bottle.fill_count} time(s)</p>
                {manage && (
                  <div className="flex flex-wrap gap-2">
                    {d.bottle.condition === "good"
                      ? <ReasonDialog trigger="Mark damaged" title="Mark bottle damaged" confirmLabel="Mark damaged" action={markBottle} hidden={{ code: d.bottle.code, action: "damaged" }} />
                      : <ReasonDialog trigger="Mark repaired" title="Mark bottle repaired" confirmLabel="Save" action={markBottle} hidden={{ code: d.bottle.code, action: "repaired" }} />}
                    {d.bottle.lifecycle === "active" && <ReasonDialog trigger="Retire bottle" triggerVariant="dangerOutline" title="Retire bottle" description="The bottle leaves circulation permanently." confirmLabel="Retire" confirmVariant="danger" action={markBottle} hidden={{ code: d.bottle.code, action: "retire" }} />}
                  </div>
                )}
                <ol className="relative space-y-3 border-l border-line pl-4 text-sm">
                  {d.history?.map((h, i) => (
                    <li key={i}>
                      <span className="absolute -left-1.5 mt-1.5 h-3 w-3 rounded-full border-2 border-white bg-ola-500" />
                      <p className="font-medium">{humanize(h.type)} <span className="font-normal text-muted">· {formatDateTime(h.at)}</span></p>
                      <p className="text-muted">{h.from} → {h.to} ({h.to_fill}){h.by && ` · ${h.by}`}{h.reason && ` · ${h.reason}`}</p>
                    </li>
                  ))}
                </ol>
              </div>
            )}
          </CardBody>
        </Card>
      </div>
    </>
  );
}
