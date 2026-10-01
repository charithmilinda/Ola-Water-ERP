import type { Metadata } from "next";
import Link from "next/link";
import { Plus } from "lucide-react";
import { requirePermission } from "@/lib/access";
import { createClient } from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/page-header";
import { Card } from "@/components/ui/card";
import { Table, Td, Th } from "@/components/ui/table";
import { Badge } from "@/components/ui/badge";
import { buttonVariants } from "@/components/ui/button";
import { humanize } from "@/lib/format";

export const metadata: Metadata = { title: "Roles & Permissions" };

export default async function RolesPage() {
  await requirePermission("roles.manage");
  const supabase = await createClient();
  const [{ data: roles }, { data: rp }, { data: ur }, { count: totalPerms }] = await Promise.all([
    supabase.from("roles").select("id, code, name, description, role_group, is_system").is("archived_at", null).order("role_group").order("name"),
    supabase.from("role_permissions").select("role_id"),
    supabase.from("user_roles").select("role_id"),
    supabase.from("permissions").select("code", { count: "exact", head: true }),
  ]);
  const permCount = new Map<string, number>();
  rp?.forEach((r) => permCount.set(r.role_id, (permCount.get(r.role_id) ?? 0) + 1));
  const userCount = new Map<string, number>();
  ur?.forEach((r) => userCount.set(r.role_id, (userCount.get(r.role_id) ?? 0) + 1));

  return (
    <>
      <PageHeader
        title="Roles & Permissions"
        description="Roles bundle permissions. Every permission is enforced by the database, not only hidden in the screen."
        actions={
          <Link href="/admin/roles/new" className={buttonVariants()}>
            <Plus className="h-4 w-4" /> New role
          </Link>
        }
      />
      <Card>
        <Table>
          <thead>
            <tr>
              <Th>Role</Th>
              <Th>Group</Th>
              <Th className="text-right">Permissions</Th>
              <Th className="text-right">Users</Th>
            </tr>
          </thead>
          <tbody>
            {roles?.map((r) => (
              <tr key={r.id} className="hover:bg-ola-50/40">
                <Td>
                  <Link href={`/admin/roles/${r.id}`} className="font-medium text-ola-700 hover:underline">
                    {r.name}
                  </Link>
                  {r.description && <span className="block text-xs text-muted">{r.description}</span>}
                </Td>
                <Td>
                  <Badge tone={r.is_system ? "blue" : "neutral"}>{humanize(r.role_group)}</Badge>
                </Td>
                <Td className="num text-right">{r.code === "super_admin" ? `All (${totalPerms ?? 0})` : (permCount.get(r.id) ?? 0)}</Td>
                <Td className="num text-right">{userCount.get(r.id) ?? 0}</Td>
              </tr>
            ))}
          </tbody>
        </Table>
      </Card>
    </>
  );
}
