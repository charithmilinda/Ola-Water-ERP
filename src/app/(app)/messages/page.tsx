import type { Metadata } from "next";
import Link from "next/link";
import { CheckCircle2, MessageCircle, XCircle } from "lucide-react";
import { requirePermission } from "@/lib/access";
import { createClient } from "@/lib/supabase/server";
import { formatDateTime, formatPhone } from "@/lib/format";
import { MESSAGE_STATUS, statusBadge } from "@/lib/labels";
import { providerStatus } from "@/lib/messaging/providers";
import { PageHeader } from "@/components/ui/page-header";
import { Card, CardBody, CardHeader } from "@/components/ui/card";
import { Table, Td, Th } from "@/components/ui/table";
import { Badge } from "@/components/ui/badge";
import { Alert } from "@/components/ui/alert";
import { EmptyState } from "@/components/ui/empty-state";
import { FormDialog } from "@/components/ui/form-dialog";
import { ReasonDialog } from "@/components/ui/reason-dialog";
import { Field, Input, Select, Textarea } from "@/components/ui/field";
import { buttonVariants } from "@/components/ui/button";
import { SendNowButton } from "./send-now";
import { cancelMessage, messagingSwitch, retryMessage, saveNotificationType, saveTemplate } from "./actions";

export const metadata: Metadata = { title: "Messages & Alerts" };

type Msg = { id: string; channel: string; to_address: string; to_name: string | null; body: string; template_code: string | null; status: string; attempts: number;
  last_error: string | null; provider: string | null; created_at: string; sent_at: string | null; customer_id: string | null };
type Template = { code: string; name: string; audience: string; channel: string; subject: string | null; body: string; whatsapp_template: string | null;
  variables: string[]; is_active: boolean };
type NType = { code: string; name: string; description: string | null; permission: string | null; in_app: boolean; email: boolean; is_active: boolean };

const TABS = [["outbox", "Outbox"], ["templates", "Customer messages"], ["alerts", "Staff alerts"]] as const;

function Ready({ ok, label, detail }: { ok: boolean; label: string; detail: string }) {
  return (
    <div className="flex items-start gap-2 rounded-lg border border-line p-3">
      {ok ? <CheckCircle2 className="mt-0.5 h-4 w-4 text-emerald-600" /> : <XCircle className="mt-0.5 h-4 w-4 text-muted" />}
      <div><p className="text-sm font-medium">{label}</p><p className="text-xs text-muted">{detail}</p></div>
    </div>
  );
}

export default async function MessagesPage({ searchParams }: { searchParams: Promise<{ tab?: string; show?: string }> }) {
  await requirePermission("settings.manage");
  const sp = await searchParams;
  const tab = TABS.some(([k]) => k === sp.tab) ? sp.tab! : "outbox";
  const show = ["queued", "failed", "sent", "all"].includes(sp.show ?? "") ? sp.show! : "all";
  const supabase = await createClient();
  let q = supabase.from("message_outbox").select("id, channel, to_address, to_name, body, template_code, status, attempts, last_error, provider, created_at, sent_at, customer_id")
    .order("created_at", { ascending: false }).limit(200);
  if (show === "queued") q = q.in("status", ["queued", "sending"]);
  else if (show !== "all") q = q.eq("status", show);
  const [{ data: msgs }, { data: templates }, { data: types }, { data: summary }, { data: perms }] = await Promise.all([
    q, supabase.from("message_templates").select("*").order("code"), supabase.from("notification_types").select("*").order("sort_order"),
    supabase.rpc("control_summary"), supabase.from("permissions").select("code, module, description").order("sort_order"),
  ]);
  const ps = providerStatus();
  const m = (summary as { messages?: { queued: number; failed: number; sent_today: number; enabled: boolean } } | null)?.messages;

  return (
    <>
      <PageHeader title="Messages & Alerts" description="SMS / WhatsApp to customers, emails to staff, and the alerts people see in the bell."
        actions={<SendNowButton />} />

      <div className="mb-6 grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <Ready ok={ps.sms.ready} label="SMS" detail={ps.sms.ready ? `Provider: ${ps.sms.provider}` : "Not set up — add the SMS keys in Vercel"} />
        <Ready ok={ps.whatsapp.ready} label="WhatsApp" detail={ps.whatsapp.ready ? "WhatsApp Cloud API" : "Not set up (optional)"} />
        <Ready ok={ps.email.ready} label="Email to staff" detail={ps.email.ready ? "Resend" : "Not set up (optional)"} />
        <Ready ok={ps.cron && ps.service_key} label="Automatic sending" detail={ps.cron && ps.service_key ? "Runs while staff use the system, and every morning"
          : !ps.service_key ? "SUPABASE_SERVICE_ROLE_KEY missing" : "CRON_SECRET missing — sending only while staff use the system"} />
      </div>

      <Card className="mb-6">
        <CardBody className="flex flex-wrap items-center justify-between gap-3">
          <div>
            <p className="font-medium">Customer messages are {m?.enabled ? <Badge tone="green">ON</Badge> : <Badge tone="neutral">OFF</Badge>}</p>
            <p className="text-sm text-muted">{m ? `${m.queued} waiting · ${m.sent_today} sent today · ${m.failed} failed this week` : ""}. Staff alerts in the bell work either way.</p>
          </div>
          <ReasonDialog trigger={m?.enabled ? "Switch off" : "Switch on"} triggerVariant={m?.enabled ? "dangerOutline" : "primary"} triggerSize="md"
            title={m?.enabled ? "Stop customer messages" : "Start sending customer messages"} reasonRequired={false}
            description={m?.enabled ? "Nothing new will be queued for customers." : "Order confirmations, delivery and payment messages, reminders and complaint updates will be queued for the templates that are on."}
            confirmLabel={m?.enabled ? "Switch off" : "Switch on"} action={messagingSwitch} hidden={{ on: m?.enabled ? "false" : "true" }} />
        </CardBody>
      </Card>

      <div className="mb-4 flex flex-wrap gap-1">
        {TABS.map(([k, l]) => <Link key={k} href={`/messages?tab=${k}`} className={buttonVariants({ variant: k === tab ? "primary" : "secondary", size: "sm" })}>{l}</Link>)}
      </div>

      {tab === "outbox" && (
        <Card>
          <CardHeader title="Outbox" actions={<div className="flex flex-wrap gap-1">{[["all", "All"], ["queued", "Waiting"], ["failed", "Failed"], ["sent", "Sent"]].map(([k, l]) => (
            <Link key={k} href={`/messages?tab=outbox&show=${k}`} className={buttonVariants({ variant: k === show ? "primary" : "secondary", size: "sm" })}>{l}</Link>))}</div>} />
          {(msgs ?? []).length === 0 ? <EmptyState icon={MessageCircle} title="No messages" /> : (
            <Table>
              <thead><tr><Th>To</Th><Th>Message</Th><Th>Status</Th><Th /></tr></thead>
              <tbody>{((msgs ?? []) as Msg[]).map((x) => { const st = statusBadge(MESSAGE_STATUS, x.status); return (
                <tr key={x.id}>
                  <Td className="whitespace-nowrap">{x.customer_id ? <Link href={`/customers/${x.customer_id}`} className="hover:underline">{x.to_name ?? "—"}</Link> : x.to_name ?? "—"}
                    <span className="block text-xs text-muted">{x.channel.toUpperCase()} · {x.channel === "email" ? x.to_address : formatPhone(x.to_address)}</span></Td>
                  <Td className="max-w-md"><span className="line-clamp-2 text-sm">{x.body}</span><span className="block text-xs text-muted">{x.template_code ?? "Alert"} · {formatDateTime(x.created_at)}</span></Td>
                  <Td><Badge tone={st.tone}>{st.label}</Badge>{x.sent_at && <span className="block text-xs text-muted">{formatDateTime(x.sent_at)}</span>}
                    {x.last_error && <span className="block max-w-xs text-xs text-red-700">{x.last_error}</span>}</Td>
                  <Td className="whitespace-nowrap text-right">
                    {["failed", "cancelled"].includes(x.status) && <ReasonDialog trigger="Send again" triggerVariant="ghost" title="Send again" reasonRequired={false} confirmLabel="Queue" action={retryMessage} hidden={{ message_id: x.id }} />}
                    {x.status === "queued" && <ReasonDialog trigger="Cancel" triggerVariant="ghost" title="Cancel this message" reasonRequired={false} confirmLabel="Cancel message" confirmVariant="danger" action={cancelMessage} hidden={{ message_id: x.id }} />}
                  </Td>
                </tr>); })}</tbody>
            </Table>)}
        </Card>
      )}

      {tab === "templates" && (
        <Card>
          <CardHeader title="Customer messages" description="English text sent by SMS (or WhatsApp). Words in {{double braces}} are filled in automatically. Keep SMS short — 160 characters is one SMS." />
          <Table>
            <thead><tr><Th>When</Th><Th>Message</Th><Th>Channel</Th><Th /></tr></thead>
            <tbody>{((templates ?? []) as Template[]).map((t) => (
              <tr key={t.code}>
                <Td className="font-medium">{t.name}{!t.is_active && <Badge tone="neutral" className="ml-1">Off</Badge>}</Td>
                <Td className="max-w-lg text-sm">{t.body}<span className="block text-xs text-muted">{t.body.length} characters</span></Td>
                <Td>{t.channel === "whatsapp" ? `WhatsApp${t.whatsapp_template ? ` (${t.whatsapp_template})` : ""}` : t.channel.toUpperCase()}</Td>
                <Td className="text-right">
                  <FormDialog trigger="Edit" triggerVariant="ghost" title={t.name} submitLabel="Save" action={saveTemplate} hidden={{ code: t.code }} wide>
                    <div className="grid gap-4 sm:grid-cols-2">
                      <Field label="Send by" htmlFor={`tc-${t.code}`}><Select id={`tc-${t.code}`} name="channel" defaultValue={t.channel}>
                        <option value="sms">SMS</option><option value="whatsapp">WhatsApp</option><option value="email">Email</option></Select></Field>
                      <Field label="WhatsApp template name" htmlFor={`tw-${t.code}`} hint="Approved in Meta; needed for WhatsApp"><Input id={`tw-${t.code}`} name="whatsapp_template" defaultValue={t.whatsapp_template ?? ""} /></Field>
                    </div>
                    <Field label="Subject (email)" htmlFor={`ts-${t.code}`}><Input id={`ts-${t.code}`} name="subject" defaultValue={t.subject ?? ""} /></Field>
                    <Field label="Message" htmlFor={`tb-${t.code}`} hint={`Available: ${["customer_name", "company_name", "company_phone", ...t.variables].filter((v, i, a) => a.indexOf(v) === i).map((v) => `{{${v}}}`).join(" ")}`}>
                      <Textarea id={`tb-${t.code}`} name="body" defaultValue={t.body} rows={4} /></Field>
                    <label className="flex items-center gap-2 text-sm"><input type="checkbox" name="is_active" defaultChecked={t.is_active} /> Send this message</label>
                    <Field label="Reason for change" htmlFor={`tr-${t.code}`}><Input id={`tr-${t.code}`} name="reason" /></Field>
                  </FormDialog>
                </Td>
              </tr>))}</tbody>
          </Table>
        </Card>
      )}

      {tab === "alerts" && (
        <Card>
          <CardHeader title="Staff alerts" description="Who sees each alert in the bell (everyone holding the permission), and whether it is also emailed." />
          <Table>
            <thead><tr><Th>Alert</Th><Th>Goes to</Th><Th>Bell</Th><Th>Email</Th><Th /></tr></thead>
            <tbody>{((types ?? []) as NType[]).map((t) => (
              <tr key={t.code} className={t.is_active ? "" : "opacity-50"}>
                <Td><span className="font-medium">{t.name}</span>{t.description && <span className="block text-xs text-muted">{t.description}</span>}</Td>
                <Td className="text-sm">{t.permission ? <span className="font-mono text-xs">{t.permission}</span> : "The person concerned / the rule's approvers"}</Td>
                <Td>{t.in_app ? "Yes" : "No"}</Td><Td>{t.email ? "Yes" : "No"}</Td>
                <Td className="text-right">
                  <FormDialog trigger="Edit" triggerVariant="ghost" title={t.name} submitLabel="Save" action={saveNotificationType} hidden={{ code: t.code }}>
                    {t.permission && <Field label="Goes to holders of" htmlFor={`np-${t.code}`}><Select id={`np-${t.code}`} name="permission" defaultValue={t.permission}>
                      {(perms ?? []).map((p) => <option key={p.code} value={p.code}>{p.module} — {p.description}</option>)}</Select></Field>}
                    <label className="flex items-center gap-2 text-sm"><input type="checkbox" name="in_app" defaultChecked={t.in_app} /> Show in the bell</label>
                    <label className="flex items-center gap-2 text-sm"><input type="checkbox" name="email" defaultChecked={t.email} /> Also email (needs email set up)</label>
                    <label className="flex items-center gap-2 text-sm"><input type="checkbox" name="is_active" defaultChecked={t.is_active} /> Alert switched on</label>
                  </FormDialog>
                </Td>
              </tr>))}</tbody>
          </Table>
        </Card>
      )}
      {!ps.sms.ready && tab === "outbox" && <Alert tone="info" className="mt-4">Messages wait in the outbox until a provider is set up. The setup guide explains the Vercel settings.</Alert>}
    </>
  );
}
