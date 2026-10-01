import type { Metadata } from "next";
import Link from "next/link";
import { Repeat } from "lucide-react";
import { requirePermission, can } from "@/lib/access";
import { createClient } from "@/lib/supabase/server";
import { formatDate, todayISO } from "@/lib/format";
import { PageHeader } from "@/components/ui/page-header";
import { Card, CardBody, CardHeader } from "@/components/ui/card";
import { Table, Td, Th } from "@/components/ui/table";
import { Badge } from "@/components/ui/badge";
import { EmptyState } from "@/components/ui/empty-state";
import { ActionForm } from "@/components/ui/action-form";
import { SubmitButton } from "@/components/ui/submit-button";
import { ReasonDialog } from "@/components/ui/reason-dialog";
import { Field, Input } from "@/components/ui/field";
import { RecurringEditor } from "./recurring-editor";
import { generateOrders, setRecurringStatus, skipNext } from "./actions";

export const metadata: Metadata = { title: "Recurring Orders" };

const DAY = ["", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
function describe(r: { frequency: string; weekdays: number[] | null; interval_days: number | null; day_of_month: number | null }) {
  switch (r.frequency) {
    case "daily": return "Every day";
    case "alternate_days": return "Every other day";
    case "weekly": return `Weekly: ${(r.weekdays ?? []).map((d) => DAY[d]).join(", ")}`;
    case "every_n_days": return `Every ${r.interval_days} days`;
    case "monthly": return `Monthly on day ${r.day_of_month}`;
  }
  return r.frequency;
}

export default async function RecurringPage() {
  const access = await requirePermission("orders.view");
  const supabase = await createClient();
  const today = todayISO();
  const tomorrow = new Date(new Date(`${today}T00:00:00Z`).getTime() + 86400000).toISOString().slice(0, 10);
  const in3 = new Date(new Date(`${today}T00:00:00Z`).getTime() + 3 * 86400000).toISOString().slice(0, 10);
  const { data } = await supabase.from("recurring_orders")
    .select("*, customer:customers(id, name, customer_no), items:recurring_order_items(qty, product:products(name))")
    .neq("status", "cancelled").order("next_date");
  const manage = can(access, "orders.manage");

  return (
    <>
      <PageHeader title="Recurring Orders" description="Standing orders become normal orders when you generate them (up to 14 days ahead). Generating twice never creates duplicates." />
      <div className="grid gap-6 xl:grid-cols-[1fr_420px]">
        <div className="space-y-6">
          {manage && (
            <Card>
              <CardBody>
                <ActionForm action={generateOrders} className="flex flex-wrap items-end gap-3 space-y-0">
                  <Field label="Create orders for deliveries up to" htmlFor="until"><Input id="until" name="until" type="date" min={today} defaultValue={in3} /></Field>
                  <SubmitButton pendingText="Generating…">Generate orders</SubmitButton>
                </ActionForm>
              </CardBody>
            </Card>
          )}
          <Card>
            {(data ?? []).length === 0 ? <EmptyState icon={Repeat} title="No recurring orders" description="Create one for customers who order on a regular schedule." /> : (
              <Table>
                <thead><tr><Th>Customer</Th><Th>Schedule</Th><Th>Items</Th><Th>Next</Th><Th /></tr></thead>
                <tbody>
                  {data?.map((r) => (
                    <tr key={r.id}>
                      <Td><Link href={`/customers/${r.customer?.id}`} className="font-medium text-ola-700 hover:underline">{r.customer?.name}</Link>
                        {r.status === "paused" && <Badge tone="amber" className="ml-2">Paused</Badge>}</Td>
                      <Td>{describe(r)}</Td>
                      <Td>{(r.items as { qty: number; product: { name: string } }[]).map((i) => `${Number(i.qty)} × ${i.product.name}`).join(", ")}</Td>
                      <Td className="whitespace-nowrap">{formatDate(r.next_date)}</Td>
                      <Td className="whitespace-nowrap text-right">
                        {manage && (
                          <div className="flex justify-end gap-1">
                            {r.status === "active" ? (
                              <>
                                <ReasonDialog trigger="Skip next" triggerVariant="ghost" title="Skip the next delivery" confirmLabel="Skip" action={skipNext} hidden={{ id: r.id }} reasonRequired={false} />
                                <ReasonDialog trigger="Pause" triggerVariant="ghost" title="Pause recurring order" confirmLabel="Pause" action={setRecurringStatus} hidden={{ id: r.id, status: "paused" }} />
                              </>
                            ) : (
                              <ReasonDialog trigger="Resume" triggerVariant="ghost" title="Resume recurring order" confirmLabel="Resume" action={setRecurringStatus} hidden={{ id: r.id, status: "active" }} reasonRequired={false} />
                            )}
                            <ReasonDialog trigger="Cancel" triggerVariant="ghost" title="Cancel recurring order" confirmLabel="Cancel it" confirmVariant="danger" action={setRecurringStatus} hidden={{ id: r.id, status: "cancelled" }} />
                          </div>
                        )}
                      </Td>
                    </tr>
                  ))}
                </tbody>
              </Table>
            )}
          </Card>
        </div>
        {manage && (
          <Card className="h-fit">
            <CardHeader title="New recurring order" />
            <CardBody><RecurringEditor tomorrow={tomorrow} /></CardBody>
          </Card>
        )}
      </div>
    </>
  );
}
