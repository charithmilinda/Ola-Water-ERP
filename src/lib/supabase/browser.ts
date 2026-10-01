"use client";

import { createBrowserClient } from "@supabase/ssr";

function deviceId(): string {
  try {
    let id = localStorage.getItem("ola_device_id");
    if (!id) {
      id = crypto.randomUUID();
      localStorage.setItem("ola_device_id", id);
    }
    return id;
  } catch {
    return "unknown";
  }
}

function deviceLabel(): string {
  const ua = navigator.userAgent;
  const browser = /Edg\//.test(ua) ? "Edge" : /Chrome\//.test(ua) ? "Chrome" : /Firefox\//.test(ua) ? "Firefox" : /Safari\//.test(ua) ? "Safari" : "Browser";
  const os = /Android/.test(ua) ? "Android" : /iPhone|iPad/.test(ua) ? "iOS" : /Windows/.test(ua) ? "Windows" : /Mac OS X/.test(ua) ? "macOS" : "Other";
  return `${browser} on ${os} [${deviceId().slice(0, 8)}]`;
}

let client: ReturnType<typeof createBrowserClient> | null = null;

/** Browser Supabase client (used by the offline-capable driver app). */
export function browserClient() {
  if (!client) {
    client = createBrowserClient(process.env.NEXT_PUBLIC_SUPABASE_URL!, process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!, {
      global: { headers: { "x-device-id": deviceLabel() } },
    });
  }
  return client;
}
