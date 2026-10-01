import "server-only";
import { cookies, headers } from "next/headers";

import { DEVICE_COOKIE_NAME as DEVICE_COOKIE } from "@/lib/constants";
export { DEVICE_COOKIE };

/** Short, human-readable description of the browser/device from the user agent. */
export function describeUserAgent(ua: string | null): string {
  if (!ua) return "Unknown device";
  const browser = /Edg\//.test(ua) ? "Edge" : /Chrome\//.test(ua) ? "Chrome" : /Firefox\//.test(ua) ? "Firefox" : /Safari\//.test(ua) ? "Safari" : "Browser";
  const os = /Android/.test(ua) ? "Android" : /iPhone|iPad/.test(ua) ? "iOS" : /Windows/.test(ua) ? "Windows" : /Mac OS X/.test(ua) ? "macOS" : /Linux/.test(ua) ? "Linux" : "Unknown OS";
  return `${browser} on ${os}`;
}

/**
 * Headers forwarded to Supabase on every server-side call so that the
 * database audit trail records the real end user's IP and device
 * (Supabase otherwise only sees the Next.js server).
 */
export async function auditHeaders(): Promise<Record<string, string>> {
  const h = await headers();
  const c = await cookies();
  const ip = (h.get("x-forwarded-for") ?? "").split(",")[0].trim() || h.get("x-real-ip") || "";
  const deviceId = c.get(DEVICE_COOKIE)?.value ?? "unregistered";
  const out: Record<string, string> = {
    "x-device-id": `${describeUserAgent(h.get("user-agent"))} [${deviceId.slice(0, 8)}]`,
    "x-request-id": h.get("x-vercel-id") ?? crypto.randomUUID(),
  };
  if (ip) out["x-client-ip"] = ip;
  return out;
}

export async function clientIp(): Promise<string | null> {
  const h = await headers();
  return (h.get("x-forwarded-for") ?? "").split(",")[0].trim() || h.get("x-real-ip") || null;
}
