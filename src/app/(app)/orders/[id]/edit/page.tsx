import type { Metadata } from "next";
import { notFound, redirect } from "next/navigation";
import { requirePermission } from "@/lib/access";
import { createClient } from "@/lib/supabase/server";
import { isUuid } from "@/lib/actions";
import { todayISO } from "@/lib/format";
import { PageHeader } from "@/components/ui/page-header";
import { Card, CardBody } from "@/components/ui/card";
import { OrderEditor } from "../../order-editor";

export const metadata: Metadata = { title: "Edit order" };

export default async function EditOrderPage({ params }: { params: Promise<{ id: string }> }) {
  await requirePermission("orders.manage");
  const { id } = await params;
  if (!isUuid(id)) notFound();
  const supabase = await createClient();
  const { data: o } = await supabase.from("orders").select("*, customer:customers(name)").eq("id", id).maybeSingle();
  if (!o) notFound();
  if (!["draft", "on_hold", "confirmed"].includes(o.status)) redirect(`/orders/${id}`);
  const { data: items } = await supabase.from("order_items").select("product_id, qty, discount").eq("order_id", id).order("line_no");
  return (
    <>
      <PageHeader title={`Edit ${o.order_no}`} description={`${o.customer?.name} — saving re-checks credit and bottle limits.`} />
      <Card>
        <CardBody>
          <OrderEditor
            today={todayISO()}
            initial={{
              id: o.id, customer_id: o.customer_id, address_id: o.address_id ?? undefined, requested_date: o.requested_date,
              time_window: o.time_window ?? "", notes: o.notes ?? "", delivery_charge: String(o.delivery_charge),
              expected_ola_returns: String(o.expected_ola_returns),
              items: (items ?? []).map((i) => ({ product_id: i.product_id, qty: String(Number(i.qty)), discount: Number(i.discount) ? String(i.discount) : "" })),
            }}
          />
        </CardBody>
      </Card>
    </>
  );
}
