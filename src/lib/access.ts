import "server-only";
import { cache } from "react";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";

export type Access = {
  user_id: string;
  full_name: string;
  email: string | null;
  is_active: boolean;
  is_super_admin: boolean;
  default_location: { id: string; code: string; name: string } | null;
  roles: { code: string; name: string; location_code: string | null }[];
  permissions: string[];
};

/** The signed-in user's profile, roles and permissions (one DB call per request). */
export const getAccess = cache(async (): Promise<Access> => {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("get_my_access");
  if (error) throw new Error(`Could not load your access: ${error.message}`);
  if (!data) redirect("/login");
  const access = data as Access;
  if (!access.is_active) redirect("/login?error=inactive");
  return access;
});

export function can(access: Access, permission: string | string[]): boolean {
  const list = Array.isArray(permission) ? permission : [permission];
  return access.is_super_admin || list.some((p) => access.permissions.includes(p));
}

/** Server-side page guard. The database enforces the same rule again. */
export async function requirePermission(permission: string | string[]): Promise<Access> {
  const access = await getAccess();
  if (!can(access, permission)) redirect("/forbidden");
  return access;
}
