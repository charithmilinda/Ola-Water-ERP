import type { Metadata } from "next";
import { requirePermission } from "@/lib/access";
import { todayISO } from "@/lib/format";
import { PageHeader } from "@/components/ui/page-header";
import { Card, CardBody } from "@/components/ui/card";
import { OrderEditor } from "../order-editor";

export const metadata: Metadata = { title: "New order" };

export default async function NewOrderPage({ searchParams }: { searchParams: Promise<{ customer?: string }> }) {
  await requirePermission("orders.manage");
  const { customer } = await searchParams;
  const today = todayISO();
  return (
    <>
      <PageHeader title="New order" description="Phone, staff and sales-rep orders. Prices come from the customer's price list." />
      <Card>
        <CardBody>
          <OrderEditor initial={{ customer_id: customer, requested_date: today }} today={today} />
        </CardBody>
      </Card>
    </>
  );
}
