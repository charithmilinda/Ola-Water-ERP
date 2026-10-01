import type { Metadata } from "next";
import Link from "next/link";
import { Users } from "lucide-react";
import { requirePermission } from "@/lib/access";
import { createClient } from "@/lib/supabase/server";
import { formatDateTime, formatPhone } from "@/lib/format";
import { PageHeader } from "@/components/ui/page-header";
import { Card, CardBody, CardHeader } from "@/components/ui/card";
import { Table, Td, Th } from "@/components/ui/table";
import { Badge } from "@/components/ui/badge";
import { EmptyState } from "@/components/ui/empty-state";
import { Alert } from "@/components/ui/alert";
import { CreateUserForm } from "./create-user-form";

export const metadata: Metadata = { title: "Users" };

type UserRow = {
  id: string;
  full_name: string;
  email: string | null;
  phone: string | null;
  employee_code: string | null;
  default_location_code: string | null;
  is_active: boolean;
  last_login_at: string | null;
  roles: { name: string; code: string; location_code: string | null }[];
};

export default async function UsersPage() {
  await requirePermission("users.manage");
  const supabase = await createClient();
  const [{ data: users, error }, { data: roles }, { data: locations }] = await Promise.all([
    supabase.rpc("admin_list_users"),
    supabase.from("roles").select("id, name").is("archived_at", null).order("name"),
    supabase.from("locations").select("id, code, name").eq("is_active", true).order("code"),
  ]);
  const list = (users ?? []) as UserRow[];

  return (
    <>
      <PageHeader title="Users" description="Staff accounts, their roles and sign-in status. There are no customer accounts in this system." />
      <div className="grid gap-6 xl:grid-cols-[1fr_400px]">
        <Card>
          <CardHeader title={`${list.filter((u) => u.is_active).length} active users`} description={`${list.length} in total`} />
          {error && <Alert tone="error" className="m-4">{error.message}</Alert>}
          {list.length === 0 ? (
            <EmptyState icon={Users} title="No users yet" />
          ) : (
            <Table>
              <thead>
                <tr>
                  <Th>Name</Th>
                  <Th>Roles</Th>
                  <Th>Status</Th>
                  <Th>Last sign-in</Th>
                </tr>
              </thead>
              <tbody>
                {list.map((u) => (
                  <tr key={u.id} className="hover:bg-ola-50/40">
                    <Td>
                      <Link href={`/admin/users/${u.id}`} className="font-medium text-ola-700 hover:underline">
                        {u.full_name}
                      </Link>
                      <span className="block text-xs text-muted">{u.email}</span>
                      {u.phone && <span className="block text-xs text-muted">{formatPhone(u.phone)}</span>}
                    </Td>
                    <Td>
                      <div className="flex flex-wrap gap-1">
                        {u.roles.length === 0 && <span className="text-xs text-muted">No role</span>}
                        {u.roles.map((r, i) => (
                          <Badge key={i} tone={r.code === "super_admin" ? "navy" : "blue"}>
                            {r.name}
                            {r.location_code && ` · ${r.location_code}`}
                          </Badge>
                        ))}
                      </div>
                    </Td>
                    <Td>{u.is_active ? <Badge tone="green">Active</Badge> : <Badge tone="neutral">Deactivated</Badge>}</Td>
                    <Td className="whitespace-nowrap text-muted">{u.last_login_at ? formatDateTime(u.last_login_at) : "Never"}</Td>
                  </tr>
                ))}
              </tbody>
            </Table>
          )}
        </Card>
        <Card className="h-fit">
          <CardHeader title="Add user" description="The user signs in with this email and the temporary password." />
          <CardBody>
            <CreateUserForm roles={roles ?? []} locations={locations ?? []} />
          </CardBody>
        </Card>
      </div>
    </>
  );
}
