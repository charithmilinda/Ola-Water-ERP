import { Field, Input, Select, Textarea } from "@/components/ui/field";
import { COMPLAINT_CHANNELS } from "@/lib/labels";

export type ComplaintFormData = {
  categories: { code: string; name: string; default_priority: string }[];
  users: { id: string; full_name: string }[];
  locations: { id: string; name: string }[];
  products: { id: string; name: string }[];
};

/** Fields of the "Log a complaint" form (used on Complaints and on a customer). */
export function ComplaintFields({ data, customer, orderNo }: { data: ComplaintFormData; customer?: { id: string; name: string } | null; orderNo?: string }) {
  return (
    <>
      <div className="grid gap-4 sm:grid-cols-3">
        <Field label="About" htmlFor="cf-cat" required>
          <Select id="cf-cat" name="category_code" required>{data.categories.map((c) => <option key={c.code} value={c.code}>{c.name}</option>)}</Select></Field>
        <Field label="Priority" htmlFor="cf-pr" hint="Blank = usual for this kind">
          <Select id="cf-pr" name="priority" defaultValue=""><option value="">Usual</option><option value="urgent">Urgent</option><option value="high">High</option>
            <option value="normal">Normal</option><option value="low">Low</option></Select></Field>
        <Field label="Received by" htmlFor="cf-ch">
          <Select id="cf-ch" name="channel" defaultValue="phone">{COMPLAINT_CHANNELS.map(([k, l]) => <option key={k} value={k}>{l}</option>)}</Select></Field>
      </div>
      <Field label="Complaint in a few words" htmlFor="cf-s" required><Input id="cf-s" name="subject" required maxLength={160} placeholder="e.g. Bottle leaking, water tastes bad" /></Field>
      <Field label="Details" htmlFor="cf-d"><Textarea id="cf-d" name="description" /></Field>
      {customer ? (
        <><input type="hidden" name="customer_id" value={customer.id} /><p className="text-sm">Customer: <strong>{customer.name}</strong></p></>
      ) : (
        <div className="grid gap-4 sm:grid-cols-3">
          <Field label="Customer no. or phone" htmlFor="cf-cu" hint="Leave empty for a non-customer"><Input id="cf-cu" name="customer_lookup" placeholder="C000123 or 0771234567" /></Field>
          <Field label="Contact name" htmlFor="cf-cn"><Input id="cf-cn" name="contact_name" /></Field>
          <Field label="Contact phone" htmlFor="cf-cp"><Input id="cf-cp" name="contact_phone" type="tel" /></Field>
        </div>
      )}
      <details className="rounded-lg border border-line p-3 text-sm">
        <summary className="cursor-pointer font-medium text-navy-800">Link an order, batch, bottle, product or shop</summary>
        <div className="mt-3 grid gap-4 sm:grid-cols-3">
          <Field label="Order no." htmlFor="cf-o"><Input id="cf-o" name="order_no" defaultValue={orderNo} placeholder="ORD-…" /></Field>
          <Field label="Batch no. (from the label)" htmlFor="cf-b"><Input id="cf-b" name="batch_no" /></Field>
          <Field label="Bottle code" htmlFor="cf-bt"><Input id="cf-bt" name="bottle_code" placeholder="OLA-BTL-…" /></Field>
          <Field label="Product" htmlFor="cf-p"><Select id="cf-p" name="product_id" defaultValue=""><option value="">—</option>
            {data.products.map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}</Select></Field>
          <Field label="Shop / location" htmlFor="cf-l"><Select id="cf-l" name="location_id" defaultValue=""><option value="">—</option>
            {data.locations.map((l) => <option key={l.id} value={l.id}>{l.name}</option>)}</Select></Field>
        </div>
      </details>
      <div className="grid gap-4 sm:grid-cols-2">
        <Field label="Who handles it" htmlFor="cf-a"><Select id="cf-a" name="assigned_to" defaultValue=""><option value="">Decide later</option>
          {data.users.map((u) => <option key={u.id} value={u.id}>{u.full_name}</option>)}</Select></Field>
        <Field label="Photos" htmlFor="cf-ph" hint="Up to 5, 5 MB each"><Input id="cf-ph" name="photos" type="file" accept="image/*" multiple className="py-1.5" /></Field>
      </div>
    </>
  );
}

export async function loadComplaintFormData(supabase: Awaited<ReturnType<typeof import("@/lib/supabase/server").createClient>>): Promise<ComplaintFormData> {
  const [{ data: categories }, { data: users }, { data: locations }, { data: products }] = await Promise.all([
    supabase.from("complaint_categories").select("code, name, default_priority").eq("is_active", true).order("sort_order"),
    supabase.rpc("staff_directory"),
    supabase.from("locations").select("id, name").eq("is_active", true).in("location_type", ["water_shop", "warehouse", "head_office"]).order("name"),
    supabase.from("products").select("id, name").eq("is_active", true).eq("item_type", "finished_good").order("sort_order"),
  ]);
  return { categories: categories ?? [], users: (users ?? []) as { id: string; full_name: string }[], locations: locations ?? [], products: products ?? [] };
}
