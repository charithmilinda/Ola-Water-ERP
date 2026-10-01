import type { Metadata } from "next";
import Link from "next/link";
import { CheckCircle2 } from "lucide-react";
import { requirePermission, can } from "@/lib/access";
import { createClient } from "@/lib/supabase/server";
import { formatDateTime, formatLKR, humanize } from "@/lib/format";
import { SEVERITY, statusBadge } from "@/lib/labels";
import { PageHeader } from "@/components/ui/page-header";
import { Card } from "@/components/ui/card";
import { Table, Td, Th } from "@/components/ui/table";
import { Badge } from "@/components/ui/badge";
import { EmptyState } from "@/components/ui/empty-state";
import { ReasonDialog } from "@/components/ui/reason-dialog";
import { Field, Select } from "@/components/ui/field";
import { buttonVariants } from "@/components/ui/button";
import { resolveException } from "./actions";

export const metadata: Metadata = { title: "Exceptions" };

// Outcomes for differences found on a delivery run (driver involved)
const RUN_OPTIONS: Record<string, [string, string][]> = {
  bottle_shortage: [["found", "Found — bring them in"], ["charge_driver", "Charge the driver (replacement value)"], ["write_off", "Write off as lost"], ["accepted", "Acknowledge only"]],
  stock_shortage: [["found", "Found — bring them in"], ["write_off", "Write off as lost"], ["charge_driver", "Charge the driver (cost)"], ["accepted", "Acknowledge only"]],
  cash_shortage: [["found", "Driver handed in the rest"], ["charge_driver", "Driver owes it (deduct later)"], ["write_off", "Write off as a loss"], ["accepted", "Acknowledge only"]],
};

// Outcomes for differences at shops, tills, counters and transfers in transit
const SITE_OPTIONS: Record<string, [string, string][]> = {
  stock_shortage: [["found", "Found — move it to where it should be"], ["write_off", "Write off as lost"], ["accepted", "Acknowledge only"]],
  stock_surplus: [["found", "Bring the extra into stock"], ["accepted", "Acknowledge only"]],
  bottle_shortage: [["found", "Found — no change needed"], ["write_off", "Write off as lost"], ["accepted", "Acknowledge only"]],
  bottle_surplus: [["found", "Bring the extra bottles into the count"], ["accepted", "Acknowledge only"]],
  cash_shortage: [["found", "Cashier handed in the rest"], ["charge_driver", "Cashier owes it (deduct later)"], ["write_off", "Write off as a loss"], ["accepted", "Acknowledge only"]],
};
const ACK: [string, string][] = [["accepted", "Acknowledge"]];

export default async function ExceptionsPage({ searchParams }: { searchParams: Promise<{ show?: string }> }) {
  const access = await requirePermission(["deliveries.reconcile", "bottles.view", "shops.settle", "inventory.adjust"]);
  const show = (await searchParams).show ?? "open";
  const supabase = await createClient();
  const { data } = await supabase.from("operation_exceptions")
    .select("*, run:route_runs(id, run_no), customer:customers(id, name), location:locations!operation_exceptions_location_id_fkey(id, name), target:locations!operation_exceptions_target_location_id_fkey(id, name)")
    .eq("status", show === "resolved" ? "resolved" : "open")
    .order("severity").order("created_at", { ascending: false }).limit(200);
  const canResolveRun = can(access, "deliveries.reconcile");
  const canResolveSite = can(access, ["deliveries.reconcile", "shops.settle", "inventory.adjust"]);
  type Row = { id: string; exception_type: string; severity: string; description: string; created_at: string; expected: number | null; actual: number | null;
    resolution: string | null; resolution_note: string | null; resolved_at: string | null; run: { id: string; run_no: string } | null; customer: { id: string; name: string } | null;
    location: { id: string; name: string } | null; target: { id: string; name: string } | null };

  return (
    <>
      <PageHeader title="Exceptions" description="Differences found during deliveries, check-ins, shop deliveries and till closing. Nothing is hidden: every exception stays on record with how it was resolved."
        actions={<div className="flex gap-2">
          <Link href="/exceptions" className={buttonVariants({ variant: show === "open" ? "primary" : "secondary", size: "md" })}>Open</Link>
          <Link href="/exceptions?show=resolved" className={buttonVariants({ variant: show === "resolved" ? "primary" : "secondary", size: "md" })}>Resolved</Link>
        </div>} />
      <Card>
        {(data ?? []).length === 0 ? <EmptyState icon={CheckCircle2} title={show === "open" ? "No open exceptions" : "No resolved exceptions yet"} /> : (
          <Table>
            <thead><tr><Th>Severity</Th><Th>What happened</Th><Th>Where</Th><Th>When</Th><Th /></tr></thead>
            <tbody>
              {((data ?? []) as unknown as Row[]).map((e) => {
                const s = statusBadge(SEVERITY, e.severity);
                const isCash = e.exception_type.startsWith("cash");
                const opts = (e.run ? RUN_OPTIONS : SITE_OPTIONS)[e.exception_type] ?? ACK;
                const canResolve = e.run ? canResolveRun : canResolveSite;
                return (
                  <tr key={e.id}>
                    <Td><Badge tone={s.tone}>{s.label}</Badge></Td>
                    <Td className="max-w-md"><span className="font-medium">{humanize(e.exception_type)}</span><span className="block text-sm">{e.description}</span>
                      {e.expected !== null && e.actual !== null && <span className="block text-xs text-muted">Difference: {isCash ? formatLKR(Number(e.actual) - Number(e.expected)) : Number(e.actual) - Number(e.expected)}</span>}
                      {e.resolution && <span className="block text-xs text-emerald-800">Resolved ({humanize(e.resolution)}): {e.resolution_note}</span>}</Td>
                    <Td>{e.run && <Link href={`/dispatch/${e.run.id}`} className="text-ola-700 hover:underline">{e.run.run_no}</Link>}
                      {!e.run && e.location && <span className="block">{e.location.name}{e.target ? ` → ${e.target.name}` : ""}</span>}
                      {e.customer && <Link href={`/customers/${e.customer.id}`} className="block text-ola-700 hover:underline">{e.customer.name}</Link>}</Td>
                    <Td className="whitespace-nowrap">{formatDateTime(e.created_at)}</Td>
                    <Td className="text-right">
                      {canResolve && show === "open" && (
                        <ReasonDialog trigger="Resolve" title="Resolve exception" description={e.description} confirmLabel="Resolve" action={resolveException} hidden={{ id: e.id }}>
                          <Field label="Outcome" htmlFor={`res-${e.id}`}>
                            <Select id={`res-${e.id}`} name="resolution" defaultValue={opts[0][0]}>
                              {opts.map(([v, l]) => <option key={v} value={v}>{l}</option>)}
                            </Select>
                          </Field>
                        </ReasonDialog>
                      )}
                    </Td>
                  </tr>
                );
              })}
            </tbody>
          </Table>
        )}
      </Card>
    </>
  );
}
