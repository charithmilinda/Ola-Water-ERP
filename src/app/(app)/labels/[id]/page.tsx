import type { Metadata } from "next";
import Link from "next/link";
import { notFound } from "next/navigation";
import { ArrowLeft } from "lucide-react";
import { requirePermission, can } from "@/lib/access";
import { createClient } from "@/lib/supabase/server";
import { isUuid } from "@/lib/actions";
import { formatDateTime } from "@/lib/format";
import { labelValue, PRINT_PART_SIZE, type Symbology } from "@/lib/barcode";
import { PageHeader } from "@/components/ui/page-header";
import { Card, CardBody, CardHeader } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { ReasonDialog } from "@/components/ui/reason-dialog";
import { Label, captionFor } from "@/components/label";
import { PrintControls } from "./print-controls";
import { cancelBatchAction } from "../actions";

export const metadata: Metadata = { title: "Label batch" };

export default async function LabelBatchPage({ params }: { params: Promise<{ id: string }> }) {
  const access = await requirePermission(["labels.print", "labels.view"]);
  const { id } = await params;
  if (!isUuid(id)) notFound();
  const supabase = await createClient();

  const { data: batch } = await supabase.from("label_batches").select("*").eq("id", id).maybeSingle();
  if (!batch) notFound();

  const [{ data: series }, { count: assigned }, { data: people }] = await Promise.all([
    supabase.from("identifier_series").select("name, padding, entity_type").eq("code", batch.series_code).single(),
    supabase.from("identifiers").select("id", { count: "exact", head: true }).eq("label_batch_id", id).eq("status", "assigned"),
    supabase.from("audit_logs").select("user_name").eq("record_type", "label_batches").eq("record_id", id).eq("action", "create").limit(1),
  ]);
  const padding = series?.padding ?? 8;

  const parts = [];
  for (let start = batch.first_value, part = 1; start <= batch.last_value; start += PRINT_PART_SIZE, part++) {
    const end = Math.min(batch.last_value, start + PRINT_PART_SIZE - 1);
    parts.push({
      part,
      from: labelValue(batch.series_code, start, padding),
      to: labelValue(batch.series_code, end, padding),
      count: end - start + 1,
    });
  }

  const preview = Array.from({ length: Math.min(6, batch.quantity) }, (_, i) => labelValue(batch.series_code, batch.first_value + i, padding));
  const canPrint = can(access, "labels.print");

  return (
    <>
      <Link href="/labels" className="no-print mb-4 inline-flex items-center gap-1.5 text-sm font-medium text-ola-700 hover:underline">
        <ArrowLeft className="h-4 w-4" /> All label batches
      </Link>
      <PageHeader
        title={batch.batch_no}
        description={`${series?.name ?? batch.series_code} · ${batch.quantity.toLocaleString()} labels`}
        actions={
          canPrint &&
          batch.status !== "cancelled" &&
          (assigned ?? 0) === 0 && (
            <ReasonDialog
              trigger="Cancel batch"
              triggerVariant="dangerOutline"
              triggerSize="md"
              title="Cancel label batch"
              description="All labels in this batch will be voided and can never be applied to a bottle. Destroy any printed copies."
              confirmLabel="Cancel batch"
              confirmVariant="danger"
              action={cancelBatchAction}
              hidden={{ batch_id: batch.id }}
            />
          )
        }
      />

      <div className="grid gap-6 lg:grid-cols-[360px_1fr]">
        <Card className="h-fit">
          <CardHeader title="Details" />
          <CardBody>
            <dl className="grid grid-cols-[auto_1fr] gap-x-4 gap-y-2.5 text-sm">
              <dt className="text-muted">Status</dt>
              <dd>
                <Badge tone={batch.status === "printed" ? "green" : batch.status === "cancelled" ? "neutral" : "amber"}>
                  {batch.status === "generated" ? "Not printed" : batch.status === "printed" ? "Printed" : "Cancelled"}
                </Badge>
              </dd>
              <dt className="text-muted">First</dt>
              <dd className="font-mono text-xs">{labelValue(batch.series_code, batch.first_value, padding)}</dd>
              <dt className="text-muted">Last</dt>
              <dd className="font-mono text-xs">{labelValue(batch.series_code, batch.last_value, padding)}</dd>
              <dt className="text-muted">Code type</dt>
              <dd>{batch.symbology === "qrcode" ? "QR code" : batch.symbology === "datamatrix" ? "Data Matrix" : "Code 128"}</dd>
              <dt className="text-muted">Size</dt>
              <dd>{batch.label_size.replace("x", " × ")} mm</dd>
              <dt className="text-muted">Applied</dt>
              <dd className="num">
                {(assigned ?? 0).toLocaleString()} of {batch.quantity.toLocaleString()}
              </dd>
              <dt className="text-muted">Times printed</dt>
              <dd className="num">{batch.print_count}</dd>
              <dt className="text-muted">Created</dt>
              <dd>
                {formatDateTime(batch.created_at)}
                {people?.[0]?.user_name && <span className="block text-muted">by {people[0].user_name}</span>}
              </dd>
              {batch.last_printed_at && (
                <>
                  <dt className="text-muted">Last printed</dt>
                  <dd>{formatDateTime(batch.last_printed_at)}</dd>
                </>
              )}
              {batch.notes && (
                <>
                  <dt className="text-muted">Notes</dt>
                  <dd>{batch.notes}</dd>
                </>
              )}
            </dl>
          </CardBody>
        </Card>

        <div className="space-y-6">
          {batch.status !== "cancelled" && (
            <Card>
              <CardHeader title="Print" description={`Printed in parts of up to ${PRINT_PART_SIZE} labels.`} />
              <CardBody>
                <PrintControls batchId={batch.id} printCount={batch.print_count} parts={parts} canPrint={canPrint} />
              </CardBody>
            </Card>
          )}
          <Card>
            <CardHeader title="Preview" description="Actual size when printed" />
            <CardBody className="flex flex-wrap gap-3 bg-surface/60">
              {preview.map((v) => (
                <div key={v} className="rounded-sm shadow-sm ring-1 ring-line">
                  <Label value={v} symbology={batch.symbology as Symbology} size={batch.label_size} caption={captionFor(batch.series_code)} />
                </div>
              ))}
            </CardBody>
          </Card>
        </div>
      </div>
    </>
  );
}
