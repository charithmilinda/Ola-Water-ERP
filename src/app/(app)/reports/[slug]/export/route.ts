import { NextResponse, type NextRequest } from "next/server";
import { getAccess, can } from "@/lib/access";
import { createClient } from "@/lib/supabase/server";
import { GROUP_PERMISSIONS, csvValue, reportBySlug, reportFilters, type Row } from "@/lib/report-catalog";

const cell = (s: string) => (/[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s);

/** Report download as CSV (opens in Excel). The database records the download in the audit trail. */
export async function GET(req: NextRequest, { params }: { params: Promise<{ slug: string }> }) {
  const access = await getAccess();
  const { slug } = await params;
  const def = reportBySlug(slug);
  if (!def) return new NextResponse("Unknown report", { status: 404 });
  if (!can(access, "reports.export") || !can(access, GROUP_PERMISSIONS[def.group])) return new NextResponse("Not allowed", { status: 403 });
  const f = reportFilters(Object.fromEntries(req.nextUrl.searchParams.entries()));
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("run_report", { p_report: slug, p: { ...f, export: true } });
  if (error) return new NextResponse(error.message, { status: 400 });
  const rows = (data ?? []) as Row[];
  const body = "﻿" + [def.columns.map((c) => cell(c.label)).join(","),
    ...rows.map((r) => def.columns.map((c) => cell(csvValue(c, r[c.key]))).join(","))].join("\r\n");
  const stamp = [f.from, f.to].filter(Boolean).join("-") || new Date().toISOString().slice(0, 10);
  return new NextResponse(body, {
    headers: { "content-type": "text/csv; charset=utf-8", "content-disposition": `attachment; filename="ola-${slug}-${stamp}.csv"` },
  });
}
