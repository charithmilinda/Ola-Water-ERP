import type { Metadata } from "next";
import { Plus } from "lucide-react";
import { requirePermission, can } from "@/lib/access";
import { createClient } from "@/lib/supabase/server";
import { formatDate, formatLKR, formatPhone } from "@/lib/format";
import { POLICIES } from "@/lib/labels";
import { PageHeader } from "@/components/ui/page-header";
import { Card, CardBody, CardHeader } from "@/components/ui/card";
import { Table, Td, Th } from "@/components/ui/table";
import { Badge } from "@/components/ui/badge";
import { FormDialog } from "@/components/ui/form-dialog";
import { Field, Input, Select } from "@/components/ui/field";
import { HandoverForm } from "./handover-form";
import { saveCompany } from "../actions";

export const metadata: Metadata = { title: "External Bottles" };

type Account = { company_id: string; company: string; code: string; held: number; on_vehicles: number; tagged_held: number; collected: number;
  returned: number; ola_received: number; held_value: number; alert_qty: number; last_handover: string | null };
type Company = { id: string; code: string; name: string; acceptance_policy: string | null; contact_person: string | null; contact_phone: string | null;
  address: string | null; holding_alert_qty: number | null; is_active: boolean; notes: string | null; is_own: boolean };
const policyLabel = Object.fromEntries(POLICIES) as Record<string, string>;

export default async function ExternalBottlesPage() {
  const access = await requirePermission("bottles.view");
  const supabase = await createClient();
  const [{ data: accounts }, { data: companies }, { data: types }, { data: handovers }, { data: setting }] = await Promise.all([
    supabase.rpc("external_bottle_accounts"),
    supabase.from("bottle_companies").select("*").eq("is_own", false).order("name"),
    supabase.from("bottle_types").select("id, name").eq("is_active", true),
    supabase.from("external_handovers").select("*, company:bottle_companies(name)").order("created_at", { ascending: false }).limit(15),
    supabase.rpc("list_settings"),
  ]);
  const defaultPolicy = ((setting ?? []) as { key: string; current_value: string }[]).find((s) => s.key === "bottles.external_policy_default")?.current_value;
  const acc = (accounts ?? []) as Account[];
  const canManage = can(access, "bottles.external");

  const companyFields = (c?: Company) => (
    <>
      <div className="grid gap-4 sm:grid-cols-2">
        <Field label="Code" htmlFor={`cc-${c?.id}`} required hint="2–8 capitals; used on tags, e.g. EXT-AQUA"><Input id={`cc-${c?.id}`} name="code" defaultValue={c?.code} required disabled={!!c} /></Field>
        <Field label="Name" htmlFor={`cn-${c?.id}`} required><Input id={`cn-${c?.id}`} name="name" defaultValue={c?.name} required /></Field>
        <Field label="Contact person" htmlFor={`cp-${c?.id}`}><Input id={`cp-${c?.id}`} name="contact_person" defaultValue={c?.contact_person ?? ""} /></Field>
        <Field label="Phone" htmlFor={`cph-${c?.id}`}><Input id={`cph-${c?.id}`} name="contact_phone" defaultValue={c?.contact_phone ? formatPhone(c.contact_phone) : ""} /></Field>
      </div>
      <Field label="Address" htmlFor={`ca-${c?.id}`}><Input id={`ca-${c?.id}`} name="address" defaultValue={c?.address ?? ""} /></Field>
      <div className="grid gap-4 sm:grid-cols-2">
        <Field label="Policy for their bottles" htmlFor={`cpol-${c?.id}`}>
          <Select id={`cpol-${c?.id}`} name="acceptance_policy" defaultValue={c?.acceptance_policy ?? ""}>
            <option value="">Use default ({policyLabel[String(defaultPolicy)] ?? "accept one-for-one"})</option>
            {POLICIES.map(([v, l]) => <option key={v} value={v}>{l}</option>)}
          </Select>
        </Field>
        <Field label="Alert when holding more than" htmlFor={`cal-${c?.id}`} hint="Blank = system default"><Input id={`cal-${c?.id}`} name="holding_alert_qty" type="number" min={0} defaultValue={c?.holding_alert_qty ?? ""} /></Field>
      </div>
      {c && <label className="flex items-center gap-2 text-sm"><input type="checkbox" name="is_active" defaultChecked={c.is_active} /> Active</label>}
    </>
  );

  return (
    <>
      <PageHeader title="External Bottles" description="Other companies' bottles collected from customers: what we hold, what we returned, and what they gave back."
        actions={canManage && <FormDialog trigger={<><Plus className="h-4 w-4" /> Add company</>} triggerSize="md" title="Add water company" submitLabel="Add company" action={saveCompany}>{companyFields()}</FormDialog>} />

      <Card className="mb-6">
        <CardHeader title="Company accounts" />
        <Table>
          <thead><tr><Th>Company</Th><Th className="text-right">Collected</Th><Th className="text-right">Returned</Th><Th className="text-right">Held now</Th><Th className="text-right">On vehicles</Th><Th className="text-right">Value held</Th><Th className="text-right">OLA bottles they returned</Th><Th>Last hand-over</Th><Th /></tr></thead>
          <tbody>
            {acc.map((a) => {
              const c = (companies as Company[] | null)?.find((x) => x.id === a.company_id);
              return (
                <tr key={a.company_id}>
                  <Td><span className="font-medium">{a.company}</span><span className="block text-xs text-muted">{c?.acceptance_policy ? policyLabel[c.acceptance_policy] : "Default policy"}</span></Td>
                  <Td className="num text-right">{a.collected}</Td>
                  <Td className="num text-right">{a.returned}</Td>
                  <Td className="num text-right font-semibold">{a.held}{Number(a.held) > Number(a.alert_qty) && <Badge tone="red" className="ml-2">Over {a.alert_qty}</Badge>}{Number(a.tagged_held) > 0 && <span className="block text-xs font-normal text-muted">{a.tagged_held} tagged</span>}</Td>
                  <Td className="num text-right">{a.on_vehicles}</Td>
                  <Td className="num text-right">{formatLKR(a.held_value)}</Td>
                  <Td className="num text-right">{a.ola_received}</Td>
                  <Td>{a.last_handover ? formatDate(a.last_handover) : "—"}</Td>
                  <Td className="text-right">{canManage && c && <FormDialog trigger="Edit" triggerVariant="ghost" title={`Edit ${c.name}`} submitLabel="Save" action={saveCompany} hidden={{ id: c.id, code: c.code }}>{companyFields(c)}</FormDialog>}</Td>
                </tr>
              );
            })}
          </tbody>
        </Table>
      </Card>

      <div className="grid gap-6 xl:grid-cols-[1fr_440px]">
        <Card>
          <CardHeader title="Recent hand-overs" />
          <Table>
            <thead><tr><Th>Hand-over</Th><Th>Company</Th><Th>Received by</Th><Th className="text-right">Given</Th><Th className="text-right">OLA back</Th></tr></thead>
            <tbody>
              {(handovers ?? []).length === 0 && <tr><Td colSpan={5} className="text-muted">No hand-overs yet.</Td></tr>}
              {handovers?.map((h) => (
                <tr key={h.id}>
                  <Td className="font-medium">{h.handover_no}<span className="block text-xs font-normal text-muted">{formatDate(h.handover_date)}</span></Td>
                  <Td>{(h.company as { name: string })?.name}</Td>
                  <Td>{h.rep_name}{h.notes && <span className="block text-xs text-muted">{h.notes}</span>}</Td>
                  <Td className="num text-right">{h.bottles_given}</Td>
                  <Td className="num text-right">{h.ola_received}</Td>
                </tr>
              ))}
            </tbody>
          </Table>
        </Card>
        {canManage && (
          <Card className="h-fit">
            <CardHeader title="Hand bottles back" description="Give a company its bottles and record any OLA bottles they return." />
            <CardBody><HandoverForm companies={(companies ?? []).filter((c) => c.is_active).map((c) => ({ id: c.id, name: c.name }))} types={types ?? []} /></CardBody>
          </Card>
        )}
      </div>
    </>
  );
}
