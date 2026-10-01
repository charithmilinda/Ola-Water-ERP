import Link from "next/link";
import { ArrowRight } from "lucide-react";
import { getAccess, can } from "@/lib/access";
import { visibleNav } from "@/lib/nav";
import { NAV_ICONS } from "@/lib/nav-icons";
import { createClient } from "@/lib/supabase/server";
import { Card, CardBody, CardHeader, Stat } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { PageHeader } from "@/components/ui/page-header";
import { todayISO } from "@/lib/format";

export async function Welcome() {
  const access = await getAccess();
  const supabase = await createClient();
  const startOfDay = new Date(`${todayISO()}T00:00:00+05:30`).toISOString();

  const stats: { label: string; value: number; hint: string }[] = [];

  if (can(access, ["labels.print", "labels.view"])) {
    const [unassigned, toPrint] = await Promise.all([
      supabase.from("identifiers").select("id", { count: "exact", head: true }).eq("status", "unassigned"),
      supabase.from("label_batches").select("id", { count: "exact", head: true }).eq("status", "generated"),
    ]);
    stats.push(
      { label: "Labels ready to apply", value: unassigned.count ?? 0, hint: "Generated, not yet linked to a bottle" },
      { label: "Label batches to print", value: toPrint.count ?? 0, hint: "Generated but never printed" },
    );
  }
  if (can(access, "audit.view")) {
    const [events, failed] = await Promise.all([
      supabase.from("audit_logs").select("id", { count: "exact", head: true }).gte("occurred_at", startOfDay),
      supabase.from("audit_logs").select("id", { count: "exact", head: true }).eq("action", "failed_login").gte("occurred_at", startOfDay),
    ]);
    stats.push(
      { label: "Audit events today", value: events.count ?? 0, hint: "Every change recorded since midnight" },
      { label: "Failed sign-ins today", value: failed.count ?? 0, hint: "Wrong password or unknown email" },
    );
  }
  if (can(access, "users.manage")) {
    const { count } = await supabase.from("profiles").select("id", { count: "exact", head: true }).eq("is_active", true);
    stats.push({ label: "Active users", value: count ?? 0, hint: "Staff who can sign in" });
  }

  const modules = visibleNav(access.is_super_admin, access.permissions, access.scoped.map((x) => x.permission))
    .flatMap((g) => g.items)
    .filter((i) => i.href !== "/");

  const firstName = access.full_name.split(" ")[0];

  return (
    <>
      <PageHeader title={`Welcome, ${firstName}`} description="Your workspace in the OLA Water ERP." />

      {stats.length > 0 && (
        <div className="mb-6 grid gap-4 sm:grid-cols-2 xl:grid-cols-5">
          {stats.map((s) => (
            <Stat key={s.label} label={s.label} value={s.value.toLocaleString("en-LK")} hint={s.hint} />
          ))}
        </div>
      )}

      <div className="grid gap-6 lg:grid-cols-3">
        <Card className="lg:col-span-2">
          <CardHeader title="Your modules" description="What your role gives you access to." />
          {modules.length === 0 ? (
            <CardBody>
              <p className="text-sm text-muted">
                Your account has no modules assigned yet. Ask an administrator to give you a role.
              </p>
            </CardBody>
          ) : (
            <ul className="divide-y divide-line">
              {modules.map((m) => {
                const Icon = NAV_ICONS[m.icon];
                return (
                  <li key={m.href}>
                    <Link href={m.href} className="flex items-center gap-4 px-5 py-4 hover:bg-ola-50/60">
                      <span className="rounded-lg bg-ola-50 p-2 text-ola-700">
                        <Icon className="h-5 w-5" aria-hidden />
                      </span>
                      <span className="flex-1 text-sm font-medium text-navy-900">{m.label}</span>
                      <ArrowRight className="h-4 w-4 text-muted" aria-hidden />
                    </Link>
                  </li>
                );
              })}
            </ul>
          )}
        </Card>

        <Card>
          <CardHeader title="Your access" />
          <CardBody className="space-y-4 text-sm">
            <div>
              <p className="mb-1.5 text-xs font-semibold uppercase tracking-wide text-muted">Roles</p>
              <div className="flex flex-wrap gap-1.5">
                {access.roles.length === 0 && <span className="text-muted">None</span>}
                {access.roles.map((r) => (
                  <Badge key={`${r.code}-${r.location_code}`} tone={r.code === "super_admin" ? "navy" : "blue"}>
                    {r.name}
                    {r.location_code && ` · ${r.location_code}`}
                  </Badge>
                ))}
              </div>
            </div>
            <div>
              <p className="mb-1 text-xs font-semibold uppercase tracking-wide text-muted">Permissions</p>
              <p className="num text-navy-900">{access.permissions.length} granted</p>
            </div>
            {access.default_location && (
              <div>
                <p className="mb-1 text-xs font-semibold uppercase tracking-wide text-muted">Default location</p>
                <p className="text-navy-900">
                  {access.default_location.name} ({access.default_location.code})
                </p>
              </div>
            )}
          </CardBody>
        </Card>
      </div>
    </>
  );
}
