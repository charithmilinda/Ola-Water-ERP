import type { Metadata } from "next";
import Link from "next/link";
import { CheckCircle2, Inbox } from "lucide-react";
import { getAccess, can } from "@/lib/access";
import { createClient } from "@/lib/supabase/server";
import { formatDate, formatDateTime, formatLKR, todayISO } from "@/lib/format";
import { APPROVAL_STATUS, statusBadge } from "@/lib/labels";
import { PageHeader } from "@/components/ui/page-header";
import { Card, CardBody, CardHeader } from "@/components/ui/card";
import { Table, Td, Th } from "@/components/ui/table";
import { Badge } from "@/components/ui/badge";
import { EmptyState } from "@/components/ui/empty-state";
import { ReasonDialog } from "@/components/ui/reason-dialog";
import { FormDialog } from "@/components/ui/form-dialog";
import { Field, Input, Select } from "@/components/ui/field";
import { buttonVariants } from "@/components/ui/button";
import { cancelApproval, decideApproval, saveApprovalRule, saveThreshold } from "./actions";

export const metadata: Metadata = { title: "Approvals" };

type Item = { source: string; id: string; ref: string; title: string; detail: string | null; amount: number | null; kind?: string; kind_name: string;
  reason?: string | null; requested_by: string | null; requested_at: string; href: string | null; level?: number; levels?: number; approved_by?: string | null };
type Mine = { id: string; ref: string; title: string; detail: string | null; amount: number | null; status: string; requested_at: string; decided_at: string | null;
  decided_by: string | null; decision_note: string | null; levels: number; levels_done: number; href: string | null };
type Rule = { kind: string; name: string; description: string; approver_permission: string; approver_roles: string; levels: number; is_active: boolean;
  threshold_setting: string | null; threshold_label: string | null; threshold: unknown; pending: number };
type BuiltIn = { name: string; rule: string; permission: string; approver_roles: string; threshold_setting: string | null; threshold: unknown; href: string };
type History = { id: string; request_no: string; kind_name: string; title: string; details: string | null; amount: number | null; status: string; requested_by: string;
  requested_at: string; decided_by: string | null; decided_at: string | null; decision_note: string | null; steps: { level: number; by: string; decision: string; note: string | null }[] };

const TABS = [["inbox", "Waiting for me"], ["mine", "My requests"], ["history", "History"], ["rules", "Rules"]] as const;

export default async function ApprovalsPage({ searchParams }: { searchParams: Promise<{ tab?: string; from?: string; to?: string }> }) {
  const access = await getAccess();
  const sp = await searchParams;
  const tab = TABS.some(([k]) => k === sp.tab) ? sp.tab! : "inbox";
  const supabase = await createClient();
  const today = todayISO();
  const to = sp.to && /^\d{4}-\d{2}-\d{2}$/.test(sp.to) ? sp.to : today;
  const from = sp.from && /^\d{4}-\d{2}-\d{2}$/.test(sp.from) ? sp.from : `${to.slice(0, 7)}-01`;
  const [{ data: inbox }, { data: rules }, { data: hist }] = await Promise.all([
    supabase.rpc("approval_inbox"),
    tab === "rules" ? supabase.rpc("approval_rules_overview") : Promise.resolve({ data: null }),
    tab === "history" ? supabase.rpc("approval_history", { p_from: from, p_to: to }) : Promise.resolve({ data: null }),
  ]);
  const items = ((inbox as { items: Item[] } | null)?.items ?? []).sort((a, b) => a.requested_at.localeCompare(b.requested_at));
  const mine = (inbox as { mine: Mine[] } | null)?.mine ?? [];
  const ro = rules as { rules: Rule[]; built_in: BuiltIn[]; permissions: { code: string; label: string }[] } | null;
  const admin = can(access, "settings.manage");
  const waitingMine = mine.filter((m) => m.status === "pending").length;

  return (
    <>
      <PageHeader title="Approvals" description="Everything waiting for your decision, from every module. Requests you send appear under My requests." />
      <div className="mb-4 flex flex-wrap gap-1">
        {TABS.filter(([k]) => k !== "rules" || admin || can(access, "approvals.act")).map(([k, l]) => (
          <Link key={k} href={`/approvals?tab=${k}`} className={buttonVariants({ variant: k === tab ? "primary" : "secondary", size: "sm" })}>
            {l}{k === "inbox" && items.length > 0 ? ` (${items.length})` : ""}{k === "mine" && waitingMine > 0 ? ` (${waitingMine})` : ""}
          </Link>))}
      </div>

      {tab === "inbox" && (items.length === 0 ? (
        <Card><EmptyState icon={CheckCircle2} title="Nothing waiting for you" description="New requests also appear in the bell at the top." /></Card>
      ) : (
        <div className="space-y-3">
          {items.map((x) => (
            <Card key={`${x.source}-${x.id}`}>
              <CardBody className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
                <div className="min-w-0">
                  <p className="text-xs font-semibold uppercase tracking-wide text-muted">{x.kind_name} · <span className="font-mono normal-case">{x.ref}</span>
                    {x.levels && x.levels > 1 ? ` · approval ${x.level} of ${x.levels}` : ""}</p>
                  <p className="mt-0.5 font-semibold text-navy-900">{x.title}</p>
                  {x.detail && <p className="mt-1 text-sm text-navy-800">{x.detail}</p>}
                  {x.reason && <p className="mt-1 text-sm text-muted">Reason given: {x.reason}</p>}
                  <p className="mt-1 text-xs text-muted">{x.requested_by ? `${x.requested_by} · ` : ""}{formatDateTime(x.requested_at)}
                    {x.approved_by ? ` · already approved by ${x.approved_by}` : ""}</p>
                </div>
                <div className="flex shrink-0 flex-wrap items-center gap-2 sm:flex-col sm:items-end">
                  {x.amount !== null && x.amount !== undefined && <p className="num text-lg font-semibold">{formatLKR(x.amount)}</p>}
                  <div className="flex flex-wrap gap-2">
                    {x.source === "request" ? <>
                      <ReasonDialog trigger="Approve" triggerVariant="primary" title={`Approve ${x.ref}`} description={x.title} reasonRequired={false}
                        confirmLabel={x.levels && x.level! < x.levels ? "Approve (level " + x.level + ")" : "Approve and carry out"} action={decideApproval}
                        hidden={{ request_id: x.id, decision: "approve" }} />
                      <ReasonDialog trigger="Reject" triggerVariant="dangerOutline" title={`Reject ${x.ref}`} description={x.title} confirmLabel="Reject"
                        confirmVariant="danger" action={decideApproval} hidden={{ request_id: x.id, decision: "reject" }} />
                      {x.href && <Link href={x.href} className={buttonVariants({ variant: "ghost", size: "sm" })}>Details</Link>}
                    </> : x.href && <Link href={x.href} className={buttonVariants({ variant: "secondary", size: "sm" })}>Open to decide</Link>}
                  </div>
                </div>
              </CardBody>
            </Card>
          ))}
        </div>
      ))}

      {tab === "mine" && (
        <Card>
          <CardHeader title="My requests" description="Actions that needed somebody else's approval." />
          {mine.length === 0 ? <EmptyState icon={Inbox} title="You have not sent anything for approval" /> : (
            <Table>
              <thead><tr><Th>Request</Th><Th>Sent</Th><Th className="text-right">Amount</Th><Th>Status</Th><Th /></tr></thead>
              <tbody>{mine.map((m) => { const st = statusBadge(APPROVAL_STATUS, m.status); return (
                <tr key={m.id}>
                  <Td><span className="font-medium">{m.title}</span><span className="block font-mono text-xs text-muted">{m.ref}</span>
                    {m.detail && <span className="block text-xs text-muted">{m.detail}</span>}</Td>
                  <Td className="whitespace-nowrap">{formatDateTime(m.requested_at)}</Td>
                  <Td className="num text-right">{m.amount !== null ? formatLKR(m.amount) : "—"}</Td>
                  <Td><Badge tone={st.tone}>{st.label}</Badge>{m.status === "pending" && m.levels > 1 && <span className="block text-xs text-muted">{m.levels_done} of {m.levels} approvals</span>}
                    {m.decided_by && <span className="block text-xs text-muted">{m.decided_by}{m.decision_note ? ` — ${m.decision_note}` : ""}</span>}</Td>
                  <Td className="text-right">{m.status === "pending" && (
                    <ReasonDialog trigger="Withdraw" triggerVariant="ghost" title={`Withdraw ${m.ref}`} confirmLabel="Withdraw" reasonRequired={false}
                      action={cancelApproval} hidden={{ request_id: m.id }} />)}</Td>
                </tr>); })}</tbody>
            </Table>
          )}
        </Card>
      )}

      {tab === "history" && (
        <Card>
          <CardHeader title="Approval history" actions={<form className="flex flex-wrap items-center gap-1"><input type="hidden" name="tab" value="history" />
            <Input type="date" name="from" defaultValue={from} className="h-8 w-40" aria-label="From" />
            <Input type="date" name="to" defaultValue={to} className="h-8 w-40" aria-label="To" />
            <button className={buttonVariants({ variant: "secondary", size: "sm" })}>Show</button></form>} />
          {((hist ?? []) as History[]).length === 0 ? <CardBody><p className="text-sm text-muted">No requests in this period.</p></CardBody> : (
            <Table>
              <thead><tr><Th>Request</Th><Th>Asked by</Th><Th className="text-right">Amount</Th><Th>Decision</Th></tr></thead>
              <tbody>{((hist ?? []) as History[]).map((h) => { const st = statusBadge(APPROVAL_STATUS, h.status); return (
                <tr key={h.id}>
                  <Td><span className="font-medium">{h.title}</span><span className="block text-xs text-muted"><span className="font-mono">{h.request_no}</span> · {h.kind_name}</span>
                    {h.details && <span className="block text-xs text-muted">{h.details}</span>}</Td>
                  <Td className="whitespace-nowrap">{h.requested_by}<span className="block text-xs text-muted">{formatDateTime(h.requested_at)}</span></Td>
                  <Td className="num text-right">{h.amount !== null ? formatLKR(h.amount) : "—"}</Td>
                  <Td><Badge tone={st.tone}>{st.label}</Badge>
                    {h.steps.map((s, i) => <span key={i} className="block text-xs text-muted">{s.decision === "approve" ? "✓" : "✗"} {s.by}{s.note ? ` — ${s.note}` : ""}</span>)}
                    {h.decided_at && <span className="block text-xs text-muted">{formatDateTime(h.decided_at)}</span>}</Td>
                </tr>); })}</tbody>
            </Table>
          )}
        </Card>
      )}

      {tab === "rules" && ro && (
        <div className="space-y-6">
          <Card>
            <CardHeader title="Approval rules" description="When one of these is needed the action is not refused: it goes to the approvers, and is carried out for the person who asked once approved." />
            <Table>
              <thead><tr><Th>Rule</Th><Th>Limit</Th><Th>Who approves</Th><Th>Approvers</Th><Th>Status</Th><Th /></tr></thead>
              <tbody>{ro.rules.map((r) => (
                <tr key={r.kind}>
                  <Td><span className="font-medium">{r.name}</span><span className="block text-xs text-muted">{r.description}</span></Td>
                  <Td className="whitespace-nowrap">{r.threshold_setting ? <>{String(r.threshold ?? "—")}<span className="block text-xs text-muted">{r.threshold_label}</span>
                    {admin && <FormDialog trigger="Change limit" triggerVariant="ghost" title={r.threshold_label ?? "Limit"} submitLabel="Save" action={saveThreshold}
                      hidden={{ key: r.threshold_setting }}>
                      <div className="grid gap-4 sm:grid-cols-2">
                        <Field label="New limit" htmlFor={`th-${r.kind}`}><Input id={`th-${r.kind}`} name="value" type="number" step="any" min={0} defaultValue={String(r.threshold ?? "")} /></Field>
                        <Field label="From" htmlFor={`thd-${r.kind}`}><Input id={`thd-${r.kind}`} name="effective_from" type="date" defaultValue={today} min={today} /></Field>
                      </div>
                      <Field label="Reason" htmlFor={`thr-${r.kind}`} required><Input id={`thr-${r.kind}`} name="reason" required /></Field>
                    </FormDialog>}</> : <span className="text-muted">Always</span>}</Td>
                  <Td>{r.approver_roles}<span className="block font-mono text-xs text-muted">{r.approver_permission}</span></Td>
                  <Td>{r.levels === 1 ? "One" : r.levels === 2 ? "Two different people" : "Three different people"}</Td>
                  <Td>{r.is_active ? <Badge tone="green">On</Badge> : <Badge tone="neutral">Off</Badge>}{r.pending > 0 && <span className="block text-xs text-muted">{r.pending} waiting</span>}</Td>
                  <Td className="text-right">{admin && (
                    <FormDialog trigger="Edit" triggerVariant="ghost" title={r.name} submitLabel="Save rule" action={saveApprovalRule} hidden={{ kind: r.kind }}>
                      <Field label="Who can approve (permission)" htmlFor={`ap-${r.kind}`}>
                        <Select id={`ap-${r.kind}`} name="approver_permission" defaultValue={r.approver_permission}>
                          {ro.permissions.map((p) => <option key={p.code} value={p.code}>{p.label}</option>)}</Select></Field>
                      <Field label="Number of approvers" htmlFor={`lv-${r.kind}`} hint="With two or three, different people must approve one after the other, and even approvers must ask.">
                        <Select id={`lv-${r.kind}`} name="levels" defaultValue={String(r.levels)}><option value="1">One</option><option value="2">Two</option><option value="3">Three</option></Select></Field>
                      <label className="flex items-center gap-2 text-sm"><input type="checkbox" name="is_active" defaultChecked={r.is_active} /> Rule switched on (off = no approval needed)</label>
                      <Field label="Reason for the change" htmlFor={`rr-${r.kind}`} required><Input id={`rr-${r.kind}`} name="reason" required /></Field>
                    </FormDialog>)}</Td>
                </tr>))}</tbody>
            </Table>
          </Card>
          <Card>
            <CardHeader title="Approvals built into modules" description="These are decided on their own screens and also appear in the inbox. Who can approve follows Roles & Permissions." />
            <Table>
              <thead><tr><Th>What</Th><Th>Rule</Th><Th>Limit</Th><Th>Who approves</Th><Th /></tr></thead>
              <tbody>{ro.built_in.map((b) => (
                <tr key={b.name}><Td className="font-medium">{b.name}</Td><Td className="text-sm">{b.rule}</Td>
                  <Td>{b.threshold_setting ? formatLKR(Number(b.threshold)) : "—"}</Td>
                  <Td>{b.approver_roles}<span className="block font-mono text-xs text-muted">{b.permission}</span></Td>
                  <Td className="text-right"><Link href={b.href} className="text-sm text-ola-700 hover:underline">Open</Link></Td></tr>))}</tbody>
            </Table>
          </Card>
          <p className="text-xs text-muted">Limits change from the date you choose (today or later); earlier decisions keep the limit that applied then. Last checked {formatDate(today)}.</p>
        </div>
      )}
    </>
  );
}
