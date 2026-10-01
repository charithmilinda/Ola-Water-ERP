import type { Metadata } from "next";
import { requirePermission, can } from "@/lib/access";
import { createClient } from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/page-header";
import { Card, CardBody } from "@/components/ui/card";
import { ActionForm } from "@/components/ui/action-form";
import { SubmitButton } from "@/components/ui/submit-button";
import { CustomerFields } from "../customer-fields";
import { createCustomer } from "../actions";

export const metadata: Metadata = { title: "New customer" };

export default async function NewCustomerPage() {
  const access = await requirePermission("customers.manage");
  const supabase = await createClient();
  const [{ data: routes }, { data: lists }] = await Promise.all([
    supabase.from("routes").select("id, name").eq("is_active", true).order("name"),
    supabase.from("price_lists").select("id, name").eq("is_active", true).order("name"),
  ]);
  return (
    <>
      <PageHeader title="New customer" description="Customers are managed by OLA staff only — there is no customer login." />
      <Card>
        <CardBody>
          <ActionForm action={createCustomer}>
            <CustomerFields routes={routes ?? []} priceLists={lists ?? []} canCredit={can(access, "customers.credit")} />
            <SubmitButton size="lg">Create customer</SubmitButton>
          </ActionForm>
        </CardBody>
      </Card>
    </>
  );
}
