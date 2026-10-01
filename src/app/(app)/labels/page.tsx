import type { Metadata } from "next";
import Link from "next/link";
import { QrCode } from "lucide-react";
import { requirePermission, can } from "@/lib/access";
import { createClient } from "@/lib/supabase/server";
import { PAGE_SIZE } from "@/lib/constants";
import { formatDateTime } from "@/lib/format";
import { PageHeader } from "@/components/ui/page-header";
import { Card, CardBody, CardHeader } from "@/components/ui/card";
import { Table, Td, Th } from "@/components/ui/table";
import { Badge } from "@/components/ui/badge";
import { EmptyState } from "@/components/ui/empty-state";
import { Pagination } from "@/components/ui/pagination";
import { Alert } from "@/components/ui/alert";
import { GenerateLabelsForm } from "./generate-form";

export const metadata: Metadata = { title: "Label Printing" };

const STATUS_TONE = { generated: "amber", printed: "green", cancelled: "neutral" } as const;
const STATUS_LABEL = { generated: "Not printed", printed: "Printed", cancelled: "Cancelled" } as const;

export default async function LabelsPage({ searchParams }: { searchParams: Promise<{ page?: string }> }) {
  const access = await requirePermission(["labels.print", "labels.view"]);
  const page = Math.max(1, Number((await searchParams).page) || 1);
  const supabase = await createClient();

  const [{ data: series }, { data: batches, count, error }] = await Promise.all([
    supabase.from("identifier_series").select("code, name, next_value, padding").eq("is_active", true).order("code"),
    supabase
      .from("label_batches")
      .select("id, batch_no, series_code, first_value, last_value, quantity, symbology, label_size, status, print_count, created_at", {
        count: "exact",
      })
      .order("created_at", { ascending: false })
      .range((page - 1) * PAGE_SIZE, page * PAGE_SIZE - 1),
  ]);

  const canPrint = can(access, "labels.print");
  const padding = Object.fromEntries((series ?? []).map((s) => [s.code, s.padding]));
  const fmt = (code: string, n: number) => `${code}-${String(n).padStart(padding[code] ?? 8, "0")}`;

  return (
    <>
      <PageHeader
        title="Label Printing"
        description="Generate unique barcode labels for OLA bottles, crates and external-bottle tags. Each label identifies one record; all business data stays in the ERP."
      />
      <div className="grid gap-6 xl:grid-cols-[420px_1fr]">
        {canPrint && (
          <Card className="h-fit">
            <CardHeader title="New label batch" />
            <CardBody>
              <GenerateLabelsForm series={series ?? []} />
            </CardBody>
          </Card>
        )}
        <Card className={canPrint ? "" : "xl:col-span-2"}>
          <CardHeader title="Label batches" description="Most recent first" />
          {error && (
            <CardBody>
              <Alert tone="error">{error.message}</Alert>
            </CardBody>
          )}
          {!error && (batches?.length ?? 0) === 0 ? (
            <EmptyState icon={QrCode} title="No labels generated yet" description="Generate your first batch to print bottle labels." />
          ) : (
            <>
              <Table>
                <thead>
                  <tr>
                    <Th>Batch</Th>
                    <Th>Range</Th>
                    <Th className="text-right">Qty</Th>
                    <Th>Type</Th>
                    <Th>Status</Th>
                    <Th>Created</Th>
                  </tr>
                </thead>
                <tbody>
                  {batches?.map((b) => (
                    <tr key={b.id} className="hover:bg-ola-50/40">
                      <Td>
                        <Link href={`/labels/${b.id}`} className="font-medium text-ola-700 hover:underline">
                          {b.batch_no}
                        </Link>
                      </Td>
                      <Td className="font-mono text-xs">
                        {fmt(b.series_code, b.first_value)}
                        <br />
                        {fmt(b.series_code, b.last_value)}
                      </Td>
                      <Td className="num text-right">{b.quantity.toLocaleString()}</Td>
                      <Td className="whitespace-nowrap">
                        {b.symbology === "qrcode" ? "QR" : b.symbology === "datamatrix" ? "Data Matrix" : "Code 128"} · {b.label_size.replace("x", "×")}
                      </Td>
                      <Td>
                        <Badge tone={STATUS_TONE[b.status as keyof typeof STATUS_TONE]}>
                          {STATUS_LABEL[b.status as keyof typeof STATUS_LABEL]}
                          {b.print_count > 1 && ` ×${b.print_count}`}
                        </Badge>
                      </Td>
                      <Td className="whitespace-nowrap text-muted">{formatDateTime(b.created_at)}</Td>
                    </tr>
                  ))}
                </tbody>
              </Table>
              <Pagination page={page} pageSize={PAGE_SIZE} total={count ?? 0} hrefFor={(p) => `/labels?page=${p}`} />
            </>
          )}
        </Card>
      </div>
    </>
  );
}
