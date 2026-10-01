"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { z } from "zod";
import { createClient } from "@/lib/supabase/server";
import { friendlyError, isUuid, str, type ActionResult } from "@/lib/actions";

const RoleSchema = z.object({
  role_id: z.union([z.literal(""), z.string().uuid()]),
  code: z.string(),
  name: z.string().min(2, "Enter a role name").max(80),
  description: z.string().max(300),
  reason: z.string().max(500),
  permissions: z.array(z.string().regex(/^[a-z_]+\.[a-z_]+$/)),
});

export async function saveRole(_prev: ActionResult, form: FormData): Promise<ActionResult> {
  const parsed = RoleSchema.safeParse({
    role_id: str(form, "role_id"),
    code: str(form, "code"),
    name: str(form, "name"),
    description: str(form, "description"),
    reason: str(form, "reason"),
    permissions: form.getAll("permissions").map(String),
  });
  if (!parsed.success) return { ok: false, message: parsed.error.issues[0].message };
  const d = parsed.data;
  const isNew = d.role_id === "";

  let code = d.code;
  if (isNew) {
    code = (d.code || d.name).toLowerCase().replace(/[^a-z0-9]+/g, "_").replace(/^_+|_+$/g, "");
    if (!/^[a-z][a-z0-9_]{2,40}$/.test(code)) return { ok: false, message: "Role code must start with a letter and be 3–41 characters." };
  } else if (!d.reason) {
    return { ok: false, message: "A reason is required to change an existing role." };
  }

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("admin_save_role", {
    p_role_id: isNew ? null : d.role_id,
    p_code: code,
    p_name: d.name,
    p_description: d.description,
    p_permissions: d.permissions,
    p_reason: d.reason || (isNew ? "New role" : null),
  });
  if (error) {
    return { ok: false, message: error.code === "23505" ? "A role with this code already exists." : friendlyError(error) };
  }
  revalidatePath("/admin/roles");
  if (isNew) redirect(`/admin/roles/${data}`);
  revalidatePath(`/admin/roles/${d.role_id}`);
  return { ok: true, message: "Role saved." };
}

export async function archiveRole(_prev: ActionResult, form: FormData): Promise<ActionResult> {
  const roleId = str(form, "role_id");
  if (!isUuid(roleId)) return { ok: false, message: "Invalid role." };
  const supabase = await createClient();
  const { error } = await supabase.rpc("admin_archive_role", { p_role_id: roleId, p_reason: str(form, "reason") });
  if (error) return { ok: false, message: friendlyError(error) };
  revalidatePath("/admin/roles");
  redirect("/admin/roles");
}
