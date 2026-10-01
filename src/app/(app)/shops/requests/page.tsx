import type { Metadata } from "next";
import Link from "next/link";
import { PackageCheck } from "lucide-react";
import { requirePermission, can } from "@/lib/access";
import { createClient } from "@/lib/supabase/server";
import { formatDate, formatDateTime } from "@/lib/format";
import { PageHeader } from "@/components/ui/page-header";
import { Card, CardBody, CardHeader } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { EmptyState } from "@/components/ui/empty-state";
import { FormDialog } from "@/components/ui/form-dialog";
import { ReasonDialog } from "@/components/ui/reason-dialog";
import { Field, Input } from "@/components/ui/field";
import { approveRequest, dispatchRequest, withdrawRequest } from "../actions";
import { BottleReturnForm } from "./bottle-return-form";

export const metadata: Metadata = { title: "Stock Requests" };

type Req = { id: string; request_no: string; status: string; requested_at: string; needed_by: string | null; notes: string | null; decision_note: string | null;
  shop: { id: string; name: string; operating_model: string } | null;
  items: { product_id: string; requested_qty: number; approved_qty: number | null; dispatched_qty: number | null; received_qty: number | null; product: { name: string } }[] };

export default async function RequestsPage() {
  const access = await requirePermission(["shops.stock_approve", "inventory.manage"]);
  const supabase = await createClient();
  const [{ data }, { data: stock }, { data: shops }, { data: companies }, { data: types }] = await Promise.all([
    supabase.from("shop_stock_requests")
      .select("id, request_no, status, requested_at, needed_by, notes, decision_note, shop:water_shops(id, name, operating_model), items:shop_stock_request_items(product_id, requested_qty, approved_qty, dispatched_qty, received_qty, product:products(name))")
      .in("status", ["submitted", "approved", "dispatched", "received_with_differences"]).order("requested_at"),
    supabase.from("inventory_balances").select("product_id, qty, location:locations!inner(code)").eq("location.code", "WH1").eq("stock_status", "available"),
    supabase.from("water_shops").select("id, name").eq("status", "active").order("name"),
    supabase.from("bottle_companies").select("id, name, is_own").eq("is_active", true).order("is_own", { ascending: false }).order("name"),
    supabase.from("bottle_types").select("id, name").eq("is_active", true),
  ]);
  const reqs = (data ?? []) as unknown as Req[];
  const wh = (pid: string) => Number((stock ?? []).find((s) => s.product_id === pid)?.qty ?? 0);
  const col = (st: string) => reqs.filter((r) => r.status === st);
  const canApprove = can(access, "shops.stock_approve");
  const canDispatch = can(access, "inventory.manage");

  const block = (title: string, desc: string, rows: Req[], render: (r: Req) => React.ReactNode) => (
    <Card>
      <CardHeader title={`${title} (${rows.length})`} description={desc} />
      {rows.length === 0 ? <CardBody><p className="text-sm text-muted">Nothing here.</p></CardBody> : (
        <ul className="divide-y divide-line">
          {rows.map((r) => (
            <li key={r.id} className="space-y-2 px-5 py-4 text-sm">
              <div className="flex flex-wrap items-center justify-between gap-2">
                <span><Link href={`/shops/${r.shop?.id}`} className="font-medium text-ola-700 hover:underline">{r.shop?.name}</Link>
                  <span className="text-muted"> · {r.request_no} · {formatDateTime(r.requested_at)}</span>
                  {r.shop?.operating_model === "dealer" && <Badge tone="amber" className="ml-2">Dealer</Badge>}
                  {r.needed_by && <Badge tone="blue" className="ml-2">Needed {formatDate(r.needed_by)}</Badge>}</span>
                <span className="flex gap-2">{render(r)}</span>
              </div>
              <p className="text-muted">{r.items.map((i) => `${i.product.name}: ${i.requested_qty}${i.approved_qty !== null ? ` / approved ${i.approved_qty}` : ""}${i.dispatched_qty !== null ? ` / sent ${i.dispatched_qty}` : ""}${i.received_qty !== null ? ` / received ${i.received_qty}` : ""}`).join(" · ")}</p>
              {(r.notes || r.decision_note) && <p className="text-xs text-muted">{[r.notes, r.decision_note].filter(Boolean).join(" — ")}</p>}
            </li>
          ))}
        </ul>
      )}
    </Card>
  );

  return (
    <>
      <PageHeader title="Stock Requests" description="Shops ask for stock → approve → warehouse dispatches → the shop confirms what arrived. Differences become exceptions." />
      {reqs.length === 0 && <Card className="mb-6"><EmptyState icon={PackageCheck} title="No open requests" /></Card>}
      <div className="grid gap-6 xl:grid-cols-2">
        <div className="space-y-6">
          {block("Waiting for approval", "Check quantities; for dealers, the credit position is checked on approval.", col("submitted"), (r) => canApprove && (
            <>
              <FormDialog trigger="Approve" triggerVariant="primary" title={`Approve ${r.request_no}`} submitLabel="Approve" action={approveRequest} hidden={{ request_id: r.id }}>
                {r.items.map((i) => (
                  <Field key={i.product_id} label={`${i.product.name} — asked ${i.requested_qty}, ${wh(i.product_id)} in warehouse`} htmlFor={`ap-${r.id}-${i.product_id}`}>
                    <Input id={`ap-${r.id}-${i.product_id}`} name={`qty:${i.product_id}`} type="number" min={0} defaultValue={Math.min(i.requested_qty, Math.max(wh(i.product_id), 0))} />
                  </Field>
                ))}
                <Field label="Note" htmlFor={`apn-${r.id}`}><Input id={`apn-${r.id}`} name="note" /></Field>
              </FormDialog>
              <ReasonDialog trigger="Reject" triggerVariant="ghost" title={`Reject ${r.request_no}`} confirmLabel="Reject" confirmVariant="danger" action={withdrawRequest} hidden={{ request_id: r.id, shop_id: r.shop?.id ?? "" }} />
            </>
          ))}
          {block("Ready to dispatch", "Pick, load and confirm what leaves the warehouse.", col("approved"), (r) => canDispatch && (
            <FormDialog trigger="Dispatch" triggerVariant="primary" title={`Dispatch ${r.request_no}`} description="Stock moves to 'in transit' until the shop confirms receipt."
              submitLabel="Confirm dispatch" action={dispatchRequest} hidden={{ request_id: r.id }}>
              {r.items.filter((i) => (i.approved_qty ?? 0) > 0).map((i) => (
                <Field key={i.product_id} label={`${i.product.name} — approved ${i.approved_qty}, ${wh(i.product_id)} in warehouse`} htmlFor={`dp-${r.id}-${i.product_id}`}>
                  <Input id={`dp-${r.id}-${i.product_id}`} name={`qty:${i.product_id}`} type="number" min={0} max={i.approved_qty ?? 0} defaultValue={i.approved_qty ?? 0} />
                </Field>
              ))}
            </FormDialog>
          ))}
        </div>
        <div className="space-y-6">
          {block("On the way", "Waiting for the shop to confirm what arrived.", col("dispatched"), () => <Badge tone="blue">In transit</Badge>)}
          {block("Received with differences", "Resolve under Exceptions.", col("received_with_differences"), () => <Link href="/exceptions" className="text-sm font-medium text-ola-700 hover:underline">Resolve</Link>)}
          {canDispatch && (
            <Card>
              <CardHeader title="Bottles back from a shop" description="Record empties and other companies' bottles that come back to the warehouse." />
              <CardBody><BottleReturnForm shops={shops ?? []} companies={companies ?? []} types={types ?? []} /></CardBody>
            </Card>
          )}
        </div>
      </div>
    </>
  );
}
