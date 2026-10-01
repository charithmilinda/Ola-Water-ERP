import type { Metadata } from "next";
import Link from "next/link";
import { ScrollText, Search } from "lucide-react";
import { requirePermission } from "@/lib/access";
import { createClient } from "@/lib/supabase/server";
import { PAGE_SIZE } from "@/lib/constants";
import { formatDateTime, humanize } from "@/lib/format";
import { PageHeader } from "@/components/ui/page-header";
import { Card } from "@/components/ui/card";
import { Table, Td, Th } from "@/components/ui/table";
import { Badge, type BadgeTone } from "@/components/ui/badge";
import { EmptyState } from "@/components/ui/empty-state";
import { Pagination } from "@/components/ui/pagination";
import { Input, Label, Select } from "@/components/ui/field";
import { Button, buttonVariants } from "@/components/ui/button";
import { Alert } from "@/components/ui/alert";
import { AuditDetails } from "./audit-details";

export const metadata: Metadata = { title: "Audit Trail" };

const MODULES = ["auth", "users", "roles", "admin", "settings", "labels", "accounting"];
const ACTIONS = [
  "login", "logout", "failed_login", "create", "create_user", "edit", "delete", "assign_role", "revoke_role",
  "grant_permission", "revoke_permission", "deactivate", "reactivate", "change_setting", "print", "reprint",
  "cancel", "post", "reverse", "close", "archive",
];

function actionTone(action: string): BadgeTone {
  if (["delete", "cancel", "revoke_role", "revoke_permission", "deactivate", "failed_login", "reverse"].includes(action)) return "red";
  if (["edit", "change_setting", "reprint", "close", "archive"].includes(action)) return "amber";
  if (["create", "create_user", "assign_role", "grant_permission", "post", "reactivate"].includes(action)) return "green";
  return "blue";
}

type Filters = { q?: string; module?: string; action?: string; user?: string; from?: string; to?: string; page?: string };

export default async function AuditPage({ searchParams }: { searchParams: Promise<Filters> }) {
  await requirePermission("audit.view");
  const f = await searchParams;
  const page = Math.max(1, Number(f.page) || 1);
  const supabase = await createClient();

  let query = supabase
    .from("audit_logs")
    .select("*", { count: "exact" })
    .order("occurred_at", { ascending: false })
    .order("id", { ascending: false })
    .range((page - 1) * PAGE_SIZE, page * PAGE_SIZE - 1);

  if (f.module) query = query.eq("module", f.module);
  if (f.action) query = query.eq("action", f.action);
  if (f.user) query = query.ilike("user_name", `%${f.user.replace(/[%_]/g, "")}%`);
  if (f.q) {
    const safe = f.q.replace(/["\\,()*%]/g, "").trim();
    if (safe) query = query.or(`record_id.eq."${safe}",record_type.eq."${safe}",reason.ilike."*${safe}*"`);
  }
  if (f.from) query = query.gte("occurred_at", new Date(`${f.from}T00:00:00+05:30`).toISOString());
  if (f.to) query = query.lt("occurred_at", new Date(new Date(`${f.to}T00:00:00+05:30`).getTime() + 86_400_000).toISOString());

  const { data: rows, count, error } = await query;

  const qs = (p: number) => {
    const params = new URLSearchParams(Object.entries({ ...f, page: String(p) }).filter(([, v]) => v) as [string, string][]);
    return `/audit?${params.toString()}`;
  };

  return (
    <>
      <PageHeader
        title="Audit Trail"
        description="Every change in the system: who did it, when, from which device, what changed and why. Records cannot be edited or deleted."
      />

      <Card className="mb-4 p-4">
        <form className="grid gap-3 sm:grid-cols-2 lg:grid-cols-6" method="get">
          <div className="lg:col-span-2">
            <Label htmlFor="q">Record ID, type or reason</Label>
            <Input id="q" name="q" defaultValue={f.q} placeholder="e.g. label_batches or a record ID" />
          </div>
          <div>
            <Label htmlFor="user">User</Label>
            <Input id="user" name="user" defaultValue={f.user} placeholder="Name" />
          </div>
          <div>
            <Label htmlFor="module">Module</Label>
            <Select id="module" name="module" defaultValue={f.module ?? ""}>
              <option value="">All modules</option>
              {MODULES.map((m) => (
                <option key={m} value={m}>
                  {humanize(m)}
                </option>
              ))}
            </Select>
          </div>
          <div>
            <Label htmlFor="action">Action</Label>
            <Select id="action" name="action" defaultValue={f.action ?? ""}>
              <option value="">All actions</option>
              {ACTIONS.map((a) => (
                <option key={a} value={a}>
                  {humanize(a)}
                </option>
              ))}
            </Select>
          </div>
          <div className="grid grid-cols-2 gap-2">
            <div>
              <Label htmlFor="from">From</Label>
              <Input id="from" name="from" type="date" defaultValue={f.from} />
            </div>
            <div>
              <Label htmlFor="to">To</Label>
              <Input id="to" name="to" type="date" defaultValue={f.to} />
            </div>
          </div>
          <div className="flex gap-2 sm:col-span-2 lg:col-span-6">
            <Button type="submit">
              <Search className="h-4 w-4" /> Filter
            </Button>
            <Link href="/audit" className={buttonVariants({ variant: "secondary" })}>
              Clear
            </Link>
          </div>
        </form>
      </Card>

      <Card>
        {error && <Alert tone="error" className="m-4">{error.message}</Alert>}
        {!error && (rows?.length ?? 0) === 0 ? (
          <EmptyState icon={ScrollText} title="No matching audit records" description="Try widening the date range or clearing filters." />
        ) : (
          <>
            <Table>
              <thead>
                <tr>
                  <Th>When</Th>
                  <Th>User</Th>
                  <Th>Action</Th>
                  <Th>Record</Th>
                  <Th>Details</Th>
                </tr>
              </thead>
              <tbody>
                {rows?.map((r) => (
                  <tr key={r.id} className="align-top">
                    <Td className="whitespace-nowrap">
                      <span className="num">{formatDateTime(r.occurred_at)}</span>
                      {r.ip_address && <span className="block text-xs text-muted">{r.ip_address}</span>}
                    </Td>
                    <Td className="min-w-40">
                      <span className="font-medium">{r.user_name ?? "System"}</span>
                      {r.roles?.length ? <span className="block text-xs text-muted">{r.roles.map(humanize).join(", ")}</span> : null}
                      {r.device && <span className="block text-xs text-muted">{r.device}</span>}
                    </Td>
                    <Td>
                      <Badge tone={actionTone(r.action)}>{humanize(r.action)}</Badge>
                      <span className="mt-1 block text-xs text-muted">{humanize(r.module)}</span>
                    </Td>
                    <Td className="min-w-44">
                      <span className="block">{humanize(r.record_type)}</span>
                      {r.record_id && <span className="block max-w-56 truncate font-mono text-xs text-muted" title={r.record_id}>{r.record_id}</span>}
                    </Td>
                    <Td className="w-full min-w-72">
                      {r.reason && (
                        <p className="mb-1.5 text-sm">
                          <span className="text-muted">Reason: </span>
                          {r.reason}
                        </p>
                      )}
                      <AuditDetails row={r} />
                    </Td>
                  </tr>
                ))}
              </tbody>
            </Table>
            <Pagination page={page} pageSize={PAGE_SIZE} total={count ?? 0} hrefFor={qs} />
          </>
        )}
      </Card>
    </>
  );
}
