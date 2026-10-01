import type { Metadata } from "next";
import Link from "next/link";
import { notFound } from "next/navigation";
import { ArrowLeft } from "lucide-react";
import { requirePermission, can } from "@/lib/access";
import { createClient } from "@/lib/supabase/server";
import { isUuid } from "@/lib/actions";
import { formatDateTime, formatPhone, humanize } from "@/lib/format";
import { PageHeader } from "@/components/ui/page-header";
import { Card, CardBody, CardHeader } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { Alert } from "@/components/ui/alert";
import { ReasonDialog } from "@/components/ui/reason-dialog";
import { Field, Input } from "@/components/ui/field";
import { ProfileForm, AssignRoleForm } from "./forms";
import { revokeRole, setUserActive, resetPassword } from "../actions";

export const metadata: Metadata = { title: "User" };

export default async function UserPage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<{ created?: string }>;
}) {
  const access = await requirePermission("users.manage");
  const { id } = await params;
  const { created } = await searchParams;
  if (!isUuid(id)) notFound();
  const supabase = await createClient();

  const { data: user } = await supabase.from("profiles").select("*").eq("id", id).maybeSingle();
  if (!user) notFound();

  const [{ data: assignments }, { data: roles }, { data: locations }, activity] = await Promise.all([
    supabase
      .from("user_roles")
      .select("id, created_at, role:roles(id, name, code), location:locations(code, name)")
      .eq("user_id", id)
      .order("created_at"),
    supabase.from("roles").select("id, name, code").is("archived_at", null).order("name"),
    supabase.from("locations").select("id, code, name").eq("is_active", true).order("code"),
    can(access, "audit.view")
      ? supabase
          .from("audit_logs")
          .select("id, occurred_at, action, module, record_type, reason")
          .eq("user_id", id)
          .order("occurred_at", { ascending: false })
          .limit(15)
      : Promise.resolve({ data: null }),
  ]);

  type Assignment = { id: string; role: { id: string; name: string; code: string } | null; location: { code: string; name: string } | null };
  const list = (assignments ?? []) as unknown as Assignment[];
  const isSelf = access.user_id === id;

  return (
    <>
      <Link href="/admin/users" className="mb-4 inline-flex items-center gap-1.5 text-sm font-medium text-ola-700 hover:underline">
        <ArrowLeft className="h-4 w-4" /> All users
      </Link>
      <PageHeader
        title={user.full_name}
        description={[user.email, user.phone ? formatPhone(user.phone) : null].filter(Boolean).join(" · ")}
        actions={
          <>
            {user.is_active ? <Badge tone="green" className="self-center">Active</Badge> : <Badge className="self-center">Deactivated</Badge>}
            <ReasonDialog
              trigger="Set temporary password"
              triggerSize="md"
              title="Set a temporary password"
              description="The user’s current password stops working immediately."
              confirmLabel="Set password"
              action={resetPassword}
              hidden={{ user_id: id }}
            >
              <Field label="New temporary password" htmlFor="new-password" required hint="At least 10 characters with a letter and a number.">
                <Input id="new-password" name="password" type="text" required minLength={10} autoComplete="new-password" />
              </Field>
            </ReasonDialog>
            {!isSelf &&
              (user.is_active ? (
                <ReasonDialog
                  trigger="Deactivate"
                  triggerVariant="dangerOutline"
                  triggerSize="md"
                  title={`Deactivate ${user.full_name}`}
                  description="They will no longer be able to sign in. Their history is kept."
                  confirmLabel="Deactivate"
                  confirmVariant="danger"
                  action={setUserActive}
                  hidden={{ user_id: id, active: "false" }}
                />
              ) : (
                <ReasonDialog
                  trigger="Reactivate"
                  triggerSize="md"
                  title={`Reactivate ${user.full_name}`}
                  confirmLabel="Reactivate"
                  action={setUserActive}
                  hidden={{ user_id: id, active: "true" }}
                />
              ))}
          </>
        }
      />
      {created && <Alert tone="success" className="mb-6">User created. Share the temporary password with them privately.</Alert>}

      <div className="grid gap-6 lg:grid-cols-2">
        <Card>
          <CardHeader title="Profile" />
          <CardBody>
            <ProfileForm user={user} locations={locations ?? []} />
          </CardBody>
        </Card>

        <div className="space-y-6">
          <Card>
            <CardHeader title="Roles" description="A user gets every permission from all of their roles." />
            <ul className="divide-y divide-line">
              {list.length === 0 && <li className="px-5 py-4 text-sm text-muted">No roles assigned — the user can sign in but sees nothing.</li>}
              {list.map((a) => (
                <li key={a.id} className="flex items-center justify-between gap-3 px-5 py-3">
                  <span className="text-sm">
                    <span className="font-medium">{a.role?.name}</span>
                    {a.location && <span className="text-muted"> · {a.location.name}</span>}
                  </span>
                  <ReasonDialog
                    trigger="Remove"
                    triggerVariant="ghost"
                    title={`Remove ${a.role?.name}`}
                    confirmLabel="Remove role"
                    confirmVariant="danger"
                    action={revokeRole}
                    hidden={{ user_role_id: a.id, user_id: id }}
                  />
                </li>
              ))}
            </ul>
            <CardBody className="border-t border-line">
              <AssignRoleForm userId={id} roles={roles ?? []} locations={locations ?? []} />
            </CardBody>
          </Card>

          {activity.data && (
            <Card>
              <CardHeader
                title="Recent activity"
                actions={
                  <Link href={`/audit?user=${encodeURIComponent(user.full_name)}`} className="text-sm font-medium text-ola-700 hover:underline">
                    Full history
                  </Link>
                }
              />
              <ul className="divide-y divide-line text-sm">
                {activity.data.length === 0 && <li className="px-5 py-4 text-muted">No activity yet.</li>}
                {activity.data.map((e) => (
                  <li key={e.id} className="flex flex-wrap items-baseline justify-between gap-2 px-5 py-2.5">
                    <span>
                      <span className="font-medium">{humanize(e.action)}</span> <span className="text-muted">{humanize(e.record_type)}</span>
                    </span>
                    <span className="num text-xs text-muted">{formatDateTime(e.occurred_at)}</span>
                  </li>
                ))}
              </ul>
            </Card>
          )}
        </div>
      </div>
    </>
  );
}
