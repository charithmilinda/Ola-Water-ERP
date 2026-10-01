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
  /** Permissions granted only at one location (e.g. a cashier limited to one shop). */
  scoped: { permission: string; location_id: string; location_code: string; location_name: string }[];
};

/** The signed-in user's profile, roles and permissions (one DB call per request). */
export const getAccess = cache(async (): Promise<Access> => {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("get_my_access");
  if (error) throw new Error(`Could not load your access: ${error.message}`);
  if (!data) redirect("/login");
  const raw = data as Access;
  const access: Access = { ...raw, scoped: raw.scoped ?? [] };
  if (!access.is_active) redirect("/login?error=inactive");
  return access;
});

export function can(access: Access, permission: string | string[]): boolean {
  const list = Array.isArray(permission) ? permission : [permission];
  return access.is_super_admin || list.some((p) => access.permissions.includes(p));
}

/** True if the user has the permission company-wide or at least at one location. */
export function canAnywhere(access: Access, permission: string | string[]): boolean {
  const list = Array.isArray(permission) ? permission : [permission];
  return can(access, list) || access.scoped.some((s) => list.includes(s.permission));
}

/** Locations where the user holds one of these permissions only locally. */
export function scopedLocations(access: Access, permission: string | string[]) {
  const list = Array.isArray(permission) ? permission : [permission];
  const seen = new Map<string, { id: string; code: string; name: string }>();
  access.scoped.filter((s) => list.includes(s.permission)).forEach((s) => seen.set(s.location_id, { id: s.location_id, code: s.location_code, name: s.location_name }));
  return [...seen.values()];
}

/** Page guard for screens that also work for location-limited staff (shops, tills). */
export async function requireAnywhere(permission: string | string[]): Promise<Access> {
  const access = await getAccess();
  if (!canAnywhere(access, permission)) redirect("/forbidden");
  return access;
}

/** Server-side page guard. The database enforces the same rule again. */
export async function requirePermission(permission: string | string[]): Promise<Access> {
  const access = await getAccess();
  if (!can(access, permission)) redirect("/forbidden");
  return access;
}
