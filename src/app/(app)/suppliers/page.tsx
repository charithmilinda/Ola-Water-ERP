import type { Metadata } from "next";
import Link from "next/link";
import { Building2, Plus } from "lucide-react";
import { requirePermission, can } from "@/lib/access";
import { createClient } from "@/lib/supabase/server";
import { formatLKR, formatPhone } from "@/lib/format";
import { PageHeader } from "@/components/ui/page-header";
import { Card } from "@/components/ui/card";
import { Table, Td, Th } from "@/components/ui/table";
import { Badge } from "@/components/ui/badge";
import { EmptyState } from "@/components/ui/empty-state";
import { FormDialog } from "@/components/ui/form-dialog";
import { SupplierFields } from "./supplier-fields";
import { createSupplier } from "./actions";

export const metadata: Metadata = { title: "Suppliers" };

type Row = { id: string; code: string; name: string; phone: string | null; city: string | null; vat_no: string | null; payment_terms_days: number;
  is_active: boolean; outstanding: number; overdue: number; open_orders: number; receipts: number; on_time_pct: number | null; rejected_pct: number | null };

export default async function SuppliersPage() {
  const access = await requirePermission(["procurement.view", "suppliers.manage", "payments.view"]);
  const supabase = await createClient();
  const { data } = await supabase.rpc("supplier_list");
  const rows = (data ?? []) as Row[];
  return (
    <>
      <PageHeader title="Suppliers" description="Who you buy from, what you owe them and how reliably they deliver."
        actions={can(access, "suppliers.manage") && (
          <FormDialog trigger={<><Plus className="h-4 w-4" /> New supplier</>} triggerVariant="primary" triggerSize="md" title="New supplier" submitLabel="Add supplier"
            action={createSupplier} wide><SupplierFields /></FormDialog>
        )} />
      <Card>
        {rows.length === 0 ? <EmptyState icon={Building2} title="No suppliers yet" /> : (
          <Table>
            <thead><tr><Th>Supplier</Th><Th>Terms</Th><Th className="text-right">We owe</Th><Th className="text-right">Overdue</Th>
              <Th className="text-right">Open orders</Th><Th className="text-right">On time</Th><Th className="text-right">Rejected</Th></tr></thead>
            <tbody>{rows.map((s) => (
              <tr key={s.id} className={s.is_active ? "hover:bg-ola-50/40" : "opacity-50"}>
                <Td><Link href={`/suppliers/${s.id}`} className="font-medium text-ola-700 hover:underline">{s.name}</Link>
                  <span className="block text-xs text-muted">{s.code}{s.city && ` · ${s.city}`}{s.phone && ` · ${formatPhone(s.phone)}`}</span>
                  {s.vat_no && <Badge tone="blue" className="mt-1">VAT registered</Badge>}</Td>
                <Td>{s.payment_terms_days === 0 ? "Cash" : `${s.payment_terms_days} days`}</Td>
                <Td className="num text-right">{formatLKR(s.outstanding)}</Td>
                <Td className={`num text-right ${Number(s.overdue) > 0 ? "font-semibold text-red-700" : "text-muted"}`}>{formatLKR(s.overdue)}</Td>
                <Td className="num text-right">{s.open_orders}</Td>
                <Td className="num text-right">{s.on_time_pct === null ? "—" : `${s.on_time_pct}%`}</Td>
                <Td className="num text-right">{s.rejected_pct === null ? "—" : `${s.rejected_pct}%`}</Td>
              </tr>
            ))}</tbody>
          </Table>
        )}
      </Card>
    </>
  );
}
