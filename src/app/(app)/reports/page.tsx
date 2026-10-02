import type { Metadata } from "next";
import Link from "next/link";
import { BarChart3, ChevronRight } from "lucide-react";
import { getAccess, can } from "@/lib/access";
import { REPORT_CATALOG, REPORT_GROUPS, GROUP_PERMISSIONS } from "@/lib/report-catalog";
import { REPORTS as ACCOUNT_REPORTS } from "@/lib/reports";
import { redirect } from "next/navigation";
import { PageHeader } from "@/components/ui/page-header";
import { Card, CardHeader } from "@/components/ui/card";

export const metadata: Metadata = { title: "Reports" };

export default async function ReportsPage() {
  const access = await getAccess();
  const groups = REPORT_GROUPS.filter((g) => can(access, GROUP_PERMISSIONS[g]));
  const accounts = can(access, "accounting.view");
  if (groups.length === 0 && !accounts) redirect("/forbidden");

  const Item = ({ href, title, description }: { href: string; title: string; description: string }) => (
    <li>
      <Link href={href} className="flex items-center justify-between gap-3 px-5 py-3 hover:bg-ola-50/50">
        <span><span className="block font-medium text-navy-900">{title}</span><span className="block text-xs text-muted">{description}</span></span>
        <ChevronRight className="h-4 w-4 shrink-0 text-muted" />
      </Link>
    </li>
  );

  return (
    <>
      <PageHeader title="Reports" description="Every report can be filtered, printed or saved as PDF, and downloaded for Excel. Downloads are recorded in the audit trail." />
      <div className="grid gap-6 lg:grid-cols-2">
        {groups.map((g) => (
          <Card key={g}>
            <CardHeader title={g} />
            <ul className="divide-y divide-line">
              {REPORT_CATALOG.filter((r) => r.group === g).map((r) => <Item key={r.slug} href={`/reports/${r.slug}`} title={r.title} description={r.description} />)}
              {g === "Delivery" && can(access, ["fleet.manage", "deliveries.manage"]) && <Item href="/fleet" title="Fleet & vehicle profitability" description="Fuel, services, documents and contribution per vehicle" />}
              {g === "Sales" && can(access, ["sales_reps.manage", "payroll.approve"]) && <Item href="/sales/commissions" title="Sales commissions" description="Monthly commission statements" />}
            </ul>
          </Card>
        ))}
        {accounts && (
          <Card>
            <CardHeader title="Accounts" description="From the general ledger" />
            <ul className="divide-y divide-line">
              {ACCOUNT_REPORTS.map((r) => <Item key={r.slug} href={`/accounting/reports/${r.slug}`} title={r.title} description={r.description} />)}
              <Item href="/payroll/statutory" title="EPF / ETF / APIT" description="Monthly statutory lists" />
              <Item href="/assets" title="Fixed asset register" description="Cost, depreciation and book value" />
            </ul>
          </Card>
        )}
      </div>
      <p className="mt-6 flex items-center gap-2 text-xs text-muted"><BarChart3 className="h-4 w-4" /> Figures are worked out from the live records each time a report is opened.</p>
    </>
  );
}
