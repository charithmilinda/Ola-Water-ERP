import type { Metadata } from "next";
import Link from "next/link";
import { notFound } from "next/navigation";
import { ArrowLeft } from "lucide-react";
import { requirePermission } from "@/lib/access";
import { createClient } from "@/lib/supabase/server";
import { isUuid } from "@/lib/actions";
import { PageHeader } from "@/components/ui/page-header";
import { Card, CardBody } from "@/components/ui/card";
import { Alert } from "@/components/ui/alert";
import { ReasonDialog } from "@/components/ui/reason-dialog";
import { RoleForm } from "./role-form";
import { archiveRole } from "../actions";

export const metadata: Metadata = { title: "Role" };

export default async function RolePage({ params }: { params: Promise<{ id: string }> }) {
  await requirePermission("roles.manage");
  const { id } = await params;
  const isNew = id === "new";
  if (!isNew && !isUuid(id)) notFound();
  const supabase = await createClient();

  const [{ data: permissions }, roleRes, grantedRes] = await Promise.all([
    supabase.from("permissions").select("code, module, description, sort_order").order("sort_order"),
    isNew ? Promise.resolve({ data: null }) : supabase.from("roles").select("*").eq("id", id).maybeSingle(),
    isNew ? Promise.resolve({ data: [] }) : supabase.from("role_permissions").select("permission_code").eq("role_id", id),
  ]);
  const role = roleRes.data;
  if (!isNew && !role) notFound();
  const granted = (grantedRes.data ?? []).map((g: { permission_code: string }) => g.permission_code);
  const locked = role?.code === "super_admin";

  return (
    <>
      <Link href="/admin/roles" className="mb-4 inline-flex items-center gap-1.5 text-sm font-medium text-ola-700 hover:underline">
        <ArrowLeft className="h-4 w-4" /> All roles
      </Link>
      <PageHeader
        title={isNew ? "New role" : role!.name}
        description={isNew ? "Choose a name and the permissions this role grants." : role!.description ?? undefined}
        actions={
          role &&
          !role.is_system && (
            <ReasonDialog
              trigger="Archive role"
              triggerVariant="dangerOutline"
              triggerSize="md"
              title="Archive role"
              description="Only possible when no user has this role."
              confirmLabel="Archive"
              confirmVariant="danger"
              action={archiveRole}
              hidden={{ role_id: role.id }}
            />
          )
        }
      />
      {locked ? (
        <Alert tone="info">The Super Admin role always has every permission and cannot be edited.</Alert>
      ) : (
        <Card>
          <CardBody>
            <RoleForm role={role} permissions={permissions ?? []} granted={granted} />
          </CardBody>
        </Card>
      )}
    </>
  );
}
