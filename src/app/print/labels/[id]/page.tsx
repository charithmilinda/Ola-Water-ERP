import { notFound } from "next/navigation";
import { requirePermission } from "@/lib/access";
import { createClient } from "@/lib/supabase/server";
import { isUuid } from "@/lib/actions";
import { LABEL_SIZES, labelValue, PRINT_PART_SIZE, type Symbology } from "@/lib/barcode";
import { Label, captionFor } from "@/components/label";
import { AutoPrint } from "./auto-print";

export const dynamic = "force-dynamic";

export default async function PrintLabels({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<{ part?: string }>;
}) {
  const access = await requirePermission("labels.print");
  const { id } = await params;
  const part = Math.max(1, Number((await searchParams).part) || 1);
  if (!isUuid(id)) notFound();

  const supabase = await createClient();
  const { data: batch } = await supabase.from("label_batches").select("*").eq("id", id).maybeSingle();
  if (!batch || batch.status === "cancelled") notFound();
  // Printing must start from the batch page, which records it in the audit trail.
  const recentlyRecorded =
    batch.last_printed_by === access.user_id &&
    batch.last_printed_at &&
    Date.now() - new Date(batch.last_printed_at).getTime() < 60 * 60 * 1000;
  if (!recentlyRecorded) {
    return (
      <div className="flex min-h-dvh flex-col items-center justify-center gap-3 px-6 text-center">
        <p className="text-lg font-semibold text-navy-900">Start printing from the label batch page</p>
        <p className="max-w-md text-sm text-muted">Each print or reprint is recorded in the audit trail before labels are shown.</p>
        <a href={`/labels/${id}`} className="font-medium text-ola-700 underline">
          Go to {batch.batch_no}
        </a>
      </div>
    );
  }
  const { data: series } = await supabase.from("identifier_series").select("padding").eq("code", batch.series_code).single();

  const start = batch.first_value + (part - 1) * PRINT_PART_SIZE;
  if (start > batch.last_value) notFound();
  const end = Math.min(batch.last_value, start + PRINT_PART_SIZE - 1);
  const size = batch.label_size as keyof typeof LABEL_SIZES;
  const { w, h } = LABEL_SIZES[size];
  const values = Array.from({ length: end - start + 1 }, (_, i) => labelValue(batch.series_code, start + i, series?.padding ?? 8));

  return (
    <>
      <style>{`
        @page { size: ${w}mm ${h}mm; margin: 0; }
        html, body { margin: 0; background: #fff; }
        .label { page-break-after: always; break-after: page; }
        @media screen { body { background: #e9eef5; } .sheet { display: flex; flex-wrap: wrap; gap: 4mm; padding: 6mm; } .label { box-shadow: 0 0 0 1px #cbd5e1; } }
      `}</style>
      <div className="no-print flex items-center justify-between bg-navy-900 px-4 py-3 text-sm text-white">
        <span>
          {batch.batch_no} · part {part} · {values.length} labels · {w}×{h} mm
        </span>
        <AutoPrint />
      </div>
      <div className="sheet">
        {values.map((v) => (
          <Label key={v} value={v} symbology={batch.symbology as Symbology} size={size} caption={captionFor(batch.series_code)} />
        ))}
      </div>
    </>
  );
}
