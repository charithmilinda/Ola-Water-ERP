"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { z } from "zod";
import { requirePermission } from "@/lib/access";
import { createClient } from "@/lib/supabase/server";
import { createAdminClient } from "@/lib/supabase/admin";
import { friendlyError, isUuid, str, type ActionResult } from "@/lib/actions";
import { normalizeSriLankanPhone } from "@/lib/format";

const optionalUuid = z.union([z.literal(""), z.string().uuid()]).transform((v) => (v === "" ? null : v));
const optionalPhone = z
  .string()
  .transform((v, ctx) => {
    if (!v) return null;
    const p = normalizeSriLankanPhone(v);
    if (!p) ctx.addIssue({ code: "custom", message: "Enter a Sri Lankan mobile number, e.g. 077 123 4567" });
    return p;
  });

const CreateUserSchema = z.object({
  full_name: z.string().min(2, "Enter the full name").max(120),
  email: z.string().trim().toLowerCase().email("Enter a valid email address"),
  phone: optionalPhone,
  employee_code: z.string().max(30),
  default_location_id: optionalUuid,
  role_id: optionalUuid,
  password: z
    .string()
    .min(10, "Temporary password must be at least 10 characters")
    .regex(/[A-Za-z]/, "Password needs a letter")
    .regex(/[0-9]/, "Password needs a number"),
});

export async function createUser(_prev: ActionResult, form: FormData): Promise<ActionResult> {
  await requirePermission("users.manage"); // checked BEFORE the service role is used
  const parsed = CreateUserSchema.safeParse({
    full_name: str(form, "full_name"),
    email: str(form, "email"),
    phone: str(form, "phone"),
    employee_code: str(form, "employee_code"),
    default_location_id: str(form, "default_location_id"),
    role_id: str(form, "role_id"),
    password: (form.get("password") as string) ?? "",
  });
  if (!parsed.success) return { ok: false, message: parsed.error.issues[0].message };
  const d = parsed.data;

  const admin = createAdminClient();
  const { data: created, error: authError } = await admin.auth.admin.createUser({
    email: d.email,
    password: d.password,
    email_confirm: true,
    user_metadata: { full_name: d.full_name },
  });
  if (authError || !created.user) {
    return {
      ok: false,
      message: /already|registered|exists/i.test(authError?.message ?? "") ? "A user with this email already exists." : friendlyError(authError),
    };
  }

  const supabase = await createClient();
  const userId = created.user.id;
  const { error: logError } = await supabase.rpc("admin_log_user_created", { p_user_id: userId, p_reason: "New user account" });
  if (logError) return { ok: false, message: `User created, but: ${friendlyError(logError)}` };
  const { error: profileError } = await supabase.rpc("admin_update_profile", {
    p_user_id: userId,
    p_full_name: d.full_name,
    p_phone: d.phone,
    p_employee_code: d.employee_code || null,
    p_default_location_id: d.default_location_id,
    p_reason: "New user account",
  });
  if (profileError) return { ok: false, message: `User created, but the profile could not be saved: ${friendlyError(profileError)}` };

  if (d.role_id) {
    const { error } = await supabase.rpc("admin_assign_role", {
      p_user_id: userId,
      p_role_id: d.role_id,
      p_location_id: null,
      p_reason: "New user account",
    });
    if (error) return { ok: false, message: `User created, but the role could not be assigned: ${friendlyError(error)}` };
  }

  revalidatePath("/admin/users");
  redirect(`/admin/users/${userId}?created=1`);
}

const ProfileSchema = z.object({
  user_id: z.string().uuid(),
  full_name: z.string().min(2, "Enter the full name").max(120),
  phone: optionalPhone,
  employee_code: z.string().max(30),
  default_location_id: optionalUuid,
  reason: z.string().max(500),
});

export async function updateProfile(_prev: ActionResult, form: FormData): Promise<ActionResult> {
  const parsed = ProfileSchema.safeParse({
    user_id: str(form, "user_id"),
    full_name: str(form, "full_name"),
    phone: str(form, "phone"),
    employee_code: str(form, "employee_code"),
    default_location_id: str(form, "default_location_id"),
    reason: str(form, "reason"),
  });
  if (!parsed.success) return { ok: false, message: parsed.error.issues[0].message };
  const d = parsed.data;
  const supabase = await createClient();
  const { error } = await supabase.rpc("admin_update_profile", {
    p_user_id: d.user_id,
    p_full_name: d.full_name,
    p_phone: d.phone,
    p_employee_code: d.employee_code || null,
    p_default_location_id: d.default_location_id,
    p_reason: d.reason || null,
  });
  if (error) return { ok: false, message: friendlyError(error) };
  revalidatePath(`/admin/users/${d.user_id}`);
  return { ok: true, message: "Profile saved." };
}

export async function assignRole(_prev: ActionResult, form: FormData): Promise<ActionResult> {
  const userId = str(form, "user_id");
  const roleId = str(form, "role_id");
  const locationId = str(form, "location_id");
  if (!isUuid(userId) || !isUuid(roleId)) return { ok: false, message: "Choose a role." };
  if (locationId && !isUuid(locationId)) return { ok: false, message: "Invalid location." };
  const supabase = await createClient();
  const { error } = await supabase.rpc("admin_assign_role", {
    p_user_id: userId,
    p_role_id: roleId,
    p_location_id: locationId || null,
    p_reason: str(form, "reason") || null,
  });
  if (error) return { ok: false, message: friendlyError(error) };
  revalidatePath(`/admin/users/${userId}`);
  return { ok: true, message: "Role assigned." };
}

export async function revokeRole(_prev: ActionResult, form: FormData): Promise<ActionResult> {
  const userRoleId = str(form, "user_role_id");
  const reason = str(form, "reason");
  if (!reason) return { ok: false, message: "A reason is required." };
  if (!isUuid(userRoleId)) return { ok: false, message: "Invalid role assignment." };
  const supabase = await createClient();
  const { error } = await supabase.rpc("admin_revoke_role", { p_user_role_id: userRoleId, p_reason: reason });
  if (error) return { ok: false, message: friendlyError(error) };
  revalidatePath(`/admin/users/${str(form, "user_id")}`);
  return { ok: true, message: "Role removed." };
}

export async function setUserActive(_prev: ActionResult, form: FormData): Promise<ActionResult> {
  await requirePermission("users.manage");
  const userId = str(form, "user_id");
  const active = str(form, "active") === "true";
  const reason = str(form, "reason");
  if (!isUuid(userId)) return { ok: false, message: "Invalid user." };
  if (!reason) return { ok: false, message: "A reason is required." };

  const supabase = await createClient();
  const { error } = await supabase.rpc("admin_set_user_active", { p_user_id: userId, p_active: active, p_reason: reason });
  if (error) return { ok: false, message: friendlyError(error) };

  // Also block / unblock sign-in at the authentication layer.
  const { error: banError } = await createAdminClient().auth.admin.updateUserById(userId, {
    ban_duration: active ? "none" : "876000h",
  });
  if (banError) return { ok: false, message: `Status saved, but sign-in could not be ${active ? "enabled" : "blocked"}: ${banError.message}` };

  revalidatePath(`/admin/users/${userId}`);
  revalidatePath("/admin/users");
  return { ok: true, message: active ? "User reactivated." : "User deactivated and signed out of new sessions." };
}

export async function resetPassword(_prev: ActionResult, form: FormData): Promise<ActionResult> {
  await requirePermission("users.manage");
  const userId = str(form, "user_id");
  const password = (form.get("password") as string) ?? "";
  const reason = str(form, "reason");
  if (!isUuid(userId)) return { ok: false, message: "Invalid user." };
  if (password.length < 10 || !/[A-Za-z]/.test(password) || !/[0-9]/.test(password)) {
    return { ok: false, message: "Use at least 10 characters including a letter and a number." };
  }
  if (!reason) return { ok: false, message: "A reason is required." };

  const supabase = await createClient();
  const { error: logError } = await supabase.rpc("admin_log_password_reset", { p_user_id: userId, p_reason: reason });
  if (logError) return { ok: false, message: friendlyError(logError) };
  const { error } = await createAdminClient().auth.admin.updateUserById(userId, { password });
  if (error) return { ok: false, message: friendlyError(error) };
  return { ok: true, message: "Temporary password set. Share it with the user privately." };
}
