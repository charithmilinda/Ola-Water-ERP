"use server";

import { redirect } from "next/navigation";
import { headers } from "next/headers";
import { z } from "zod";
import { createClient } from "@/lib/supabase/server";
import { createAdminClient } from "@/lib/supabase/admin";
import { clientIp, describeUserAgent } from "@/lib/request-context";
import type { ActionResult } from "@/lib/actions";

const LoginSchema = z.object({
  email: z.string().trim().toLowerCase().email("Enter a valid email address"),
  password: z.string().min(1, "Enter your password"),
  next: z.string().optional(),
});

export async function signIn(_prev: ActionResult, form: FormData): Promise<ActionResult> {
  const parsed = LoginSchema.safeParse({
    email: form.get("email"),
    password: form.get("password"),
    next: form.get("next") ?? undefined,
  });
  if (!parsed.success) return { ok: false, message: parsed.error.issues[0].message };

  const supabase = await createClient();
  const { error } = await supabase.auth.signInWithPassword({
    email: parsed.data.email,
    password: parsed.data.password,
  });

  if (error) {
    // Record the failed attempt (there is no signed-in user, so the service role writes it).
    try {
      const h = await headers();
      await createAdminClient().rpc("log_failed_login", {
        p_email: parsed.data.email,
        p_ip: await clientIp(),
        p_device: describeUserAgent(h.get("user-agent")),
        p_message: error.message,
      });
    } catch {
      // Logging must never block the user from seeing the login error.
    }
    return { ok: false, message: "Incorrect email or password." };
  }

  const { data: access } = await supabase.rpc("get_my_access");
  if (!access || access.is_active === false) {
    await supabase.auth.signOut();
    return { ok: false, message: "Your account is deactivated. Contact your administrator." };
  }

  await supabase.rpc("log_auth_event", { p_action: "login" });

  const next = parsed.data.next && parsed.data.next.startsWith("/") && !parsed.data.next.startsWith("//") ? parsed.data.next : "/";
  redirect(next);
}

export async function signOut() {
  const supabase = await createClient();
  await supabase.rpc("log_auth_event", { p_action: "logout" });
  await supabase.auth.signOut();
  redirect("/login");
}
