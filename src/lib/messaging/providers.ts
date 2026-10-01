import "server-only";

/**
 * Message providers. Each one is configured only through environment
 * variables in Vercel (never stored in the database), so API keys stay secret.
 *
 *   SMS       SMS_PROVIDER = notify_lk | text_lk | webhook
 *             notify_lk: NOTIFYLK_USER_ID, NOTIFYLK_API_KEY, NOTIFYLK_SENDER_ID
 *             text_lk:   TEXTLK_API_TOKEN, TEXTLK_SENDER_ID
 *             webhook:   SMS_WEBHOOK_URL (POST JSON {to, message}), optional SMS_WEBHOOK_TOKEN
 *   WhatsApp  WHATSAPP_TOKEN, WHATSAPP_PHONE_NUMBER_ID, optional WHATSAPP_LANGUAGE (default "en")
 *   Email     RESEND_API_KEY, EMAIL_FROM (e.g. "OLA Water <no-reply@olawater.lk>")
 */

export type OutboxMessage = {
  id: string;
  channel: "sms" | "whatsapp" | "email";
  to_address: string;
  to_name: string | null;
  subject: string | null;
  body: string;
  wa_template: string | null;
  wa_params: string[] | null;
};

export type SendResult = { ok: true; provider: string; ref: string | null } | { ok: false; provider: string; error: string };

const env = (k: string) => process.env[k]?.trim() || "";
const digits = (phone: string) => phone.replace(/[^0-9]/g, "");

async function readError(res: Response) {
  const text = await res.text().catch(() => "");
  return `${res.status} ${res.statusText}${text ? `: ${text.slice(0, 300)}` : ""}`;
}

async function sendSms(m: OutboxMessage): Promise<SendResult> {
  const provider = env("SMS_PROVIDER");
  if (provider === "notify_lk") {
    if (!env("NOTIFYLK_USER_ID") || !env("NOTIFYLK_API_KEY") || !env("NOTIFYLK_SENDER_ID")) return { ok: false, provider, error: "Not configured: NOTIFYLK_USER_ID, NOTIFYLK_API_KEY and NOTIFYLK_SENDER_ID are needed" };
    const url = new URL("https://app.notify.lk/api/v1/send");
    url.searchParams.set("user_id", env("NOTIFYLK_USER_ID"));
    url.searchParams.set("api_key", env("NOTIFYLK_API_KEY"));
    url.searchParams.set("sender_id", env("NOTIFYLK_SENDER_ID"));
    url.searchParams.set("to", digits(m.to_address));
    url.searchParams.set("message", m.body);
    const res = await fetch(url, { method: "GET", cache: "no-store" });
    if (!res.ok) return { ok: false, provider, error: await readError(res) };
    const j = (await res.json().catch(() => ({}))) as { status?: string; data?: unknown; message?: string };
    return j.status === "success" ? { ok: true, provider, ref: null } : { ok: false, provider, error: j.message ?? JSON.stringify(j).slice(0, 300) };
  }
  if (provider === "text_lk") {
    if (!env("TEXTLK_API_TOKEN") || !env("TEXTLK_SENDER_ID")) return { ok: false, provider, error: "Not configured: TEXTLK_API_TOKEN and TEXTLK_SENDER_ID are needed" };
    const res = await fetch("https://app.text.lk/api/v3/sms/send", {
      method: "POST", cache: "no-store",
      headers: { Authorization: `Bearer ${env("TEXTLK_API_TOKEN")}`, "Content-Type": "application/json", Accept: "application/json" },
      body: JSON.stringify({ recipient: digits(m.to_address), sender_id: env("TEXTLK_SENDER_ID"), type: "plain", message: m.body }),
    });
    if (!res.ok) return { ok: false, provider, error: await readError(res) };
    const j = (await res.json().catch(() => ({}))) as { status?: string; message?: string; data?: { uid?: string } };
    return j.status === "success" ? { ok: true, provider, ref: j.data?.uid ?? null } : { ok: false, provider, error: j.message ?? "Rejected by Text.lk" };
  }
  if (provider === "webhook") {
    if (!env("SMS_WEBHOOK_URL")) return { ok: false, provider, error: "Not configured: SMS_WEBHOOK_URL is needed" };
    const res = await fetch(env("SMS_WEBHOOK_URL"), {
      method: "POST", cache: "no-store",
      headers: { "Content-Type": "application/json", ...(env("SMS_WEBHOOK_TOKEN") ? { Authorization: `Bearer ${env("SMS_WEBHOOK_TOKEN")}` } : {}) },
      body: JSON.stringify({ to: m.to_address, message: m.body }),
    });
    return res.ok ? { ok: true, provider, ref: null } : { ok: false, provider, error: await readError(res) };
  }
  return { ok: false, provider: provider || "sms", error: "Not configured: set SMS_PROVIDER in Vercel" };
}

async function sendWhatsApp(m: OutboxMessage): Promise<SendResult> {
  const provider = "whatsapp_cloud";
  if (!env("WHATSAPP_TOKEN") || !env("WHATSAPP_PHONE_NUMBER_ID")) return { ok: false, provider, error: "Not configured: WHATSAPP_TOKEN and WHATSAPP_PHONE_NUMBER_ID are needed" };
  const body = m.wa_template
    ? {
        messaging_product: "whatsapp", to: digits(m.to_address), type: "template",
        template: {
          name: m.wa_template, language: { code: env("WHATSAPP_LANGUAGE") || "en" },
          components: (m.wa_params ?? []).length ? [{ type: "body", parameters: (m.wa_params ?? []).map((t) => ({ type: "text", text: String(t) })) }] : [],
        },
      }
    : { messaging_product: "whatsapp", to: digits(m.to_address), type: "text", text: { body: m.body } };
  const res = await fetch(`https://graph.facebook.com/v21.0/${env("WHATSAPP_PHONE_NUMBER_ID")}/messages`, {
    method: "POST", cache: "no-store",
    headers: { Authorization: `Bearer ${env("WHATSAPP_TOKEN")}`, "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  if (!res.ok) return { ok: false, provider, error: await readError(res) };
  const j = (await res.json().catch(() => ({}))) as { messages?: { id: string }[] };
  return { ok: true, provider, ref: j.messages?.[0]?.id ?? null };
}

async function sendEmail(m: OutboxMessage): Promise<SendResult> {
  const provider = "resend";
  if (!env("RESEND_API_KEY") || !env("EMAIL_FROM")) return { ok: false, provider, error: "Not configured: RESEND_API_KEY and EMAIL_FROM are needed" };
  const res = await fetch("https://api.resend.com/emails", {
    method: "POST", cache: "no-store",
    headers: { Authorization: `Bearer ${env("RESEND_API_KEY")}`, "Content-Type": "application/json" },
    body: JSON.stringify({ from: env("EMAIL_FROM"), to: [m.to_address], subject: m.subject || "OLA Water", text: m.body }),
  });
  if (!res.ok) return { ok: false, provider, error: await readError(res) };
  const j = (await res.json().catch(() => ({}))) as { id?: string };
  return { ok: true, provider, ref: j.id ?? null };
}

export async function sendMessage(m: OutboxMessage): Promise<SendResult> {
  try {
    if (m.channel === "sms") return await sendSms(m);
    if (m.channel === "whatsapp") return await sendWhatsApp(m);
    return await sendEmail(m);
  } catch (e) {
    return { ok: false, provider: m.channel, error: e instanceof Error ? e.message : String(e) };
  }
}

/** Which channels are set up (shown on the Messages screen; never shows the keys). */
export function providerStatus() {
  const sms = env("SMS_PROVIDER");
  const smsReady =
    (sms === "notify_lk" && !!env("NOTIFYLK_USER_ID") && !!env("NOTIFYLK_API_KEY") && !!env("NOTIFYLK_SENDER_ID")) ||
    (sms === "text_lk" && !!env("TEXTLK_API_TOKEN") && !!env("TEXTLK_SENDER_ID")) ||
    (sms === "webhook" && !!env("SMS_WEBHOOK_URL"));
  return {
    sms: { ready: smsReady, provider: sms || null },
    whatsapp: { ready: !!env("WHATSAPP_TOKEN") && !!env("WHATSAPP_PHONE_NUMBER_ID"), provider: "WhatsApp Cloud API" },
    email: { ready: !!env("RESEND_API_KEY") && !!env("EMAIL_FROM"), provider: "Resend" },
    cron: !!env("CRON_SECRET"),
    service_key: !!env("SUPABASE_SERVICE_ROLE_KEY"),
  };
}
