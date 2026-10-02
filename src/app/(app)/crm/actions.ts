"use server";

import { redirect } from "next/navigation";
import { runRpc, runRpcOrApproval } from "@/lib/rpc";
import { str, type ActionResult } from "@/lib/actions";

const P = ["/crm", "/sales/my"];
const num = (f: FormData, k: string) => (str(f, k) === "" ? null : Number(str(f, k)));
const list = (f: FormData, k: string) => f.getAll(k).map(String).filter(Boolean);

function leadPayload(f: FormData) {
  return {
    name: str(f, "name"), company_name: str(f, "company_name"), contact_person: str(f, "contact_person"), phone: str(f, "phone"), email: str(f, "email"),
    address_line: str(f, "address_line"), city: str(f, "city"), customer_type: str(f, "customer_type") || null, source: str(f, "source") || null,
    campaign_id: str(f, "campaign_id") || null, territory_id: str(f, "territory_id") || null, owner_id: str(f, "owner_id") || null,
    status: str(f, "status") || null, est_monthly_bottles: num(f, "est_monthly_bottles"), est_monthly_value: num(f, "est_monthly_value"),
    next_follow_up: str(f, "next_follow_up") || null, lost_reason: str(f, "lost_reason") || null, notes: str(f, "notes"),
  };
}

export async function createLead(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const res = await runRpc<{ lead_id: string; lead_no: string }>("save_lead", { p_id: null, p: leadPayload(f) }, (d) => `${d.lead_no} added.`, P);
  if (!res.ok) return res;
  redirect(`/crm/leads/${res.data!.lead_id}`);
}

export async function updateLead(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const id = str(f, "id");
  return runRpc("save_lead", { p_id: id, p: leadPayload(f) }, "Saved.", [...P, `/crm/leads/${id}`]);
}

export async function logActivity(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const lead = str(f, "lead_id");
  const done = str(f, "mode") !== "plan";
  return runRpc("log_crm_activity", { p: {
    lead_id: lead || null, customer_id: str(f, "customer_id") || null, opportunity_id: str(f, "opportunity_id") || null, kind: str(f, "kind"),
    subject: str(f, "subject"), notes: str(f, "notes"), due_on: str(f, "due_on") || null, done, outcome: str(f, "outcome") || null,
  } }, done ? "Recorded." : "Follow-up planned.", [...P, lead ? `/crm/leads/${lead}` : "/crm"]);
}

export async function completeActivity(_p: ActionResult, f: FormData): Promise<ActionResult> {
  return runRpc("complete_crm_activity", { p_id: str(f, "activity_id"), p_outcome: str(f, "reason") || null }, "Done.", [...P, `/crm/leads/${str(f, "lead_id")}`]);
}

export async function saveOpportunity(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const lead = str(f, "lead_id");
  return runRpc("save_opportunity", { p_id: str(f, "id") || null, p: {
    title: str(f, "title"), lead_id: lead || null, customer_id: str(f, "customer_id") || null, owner_id: str(f, "owner_id") || null, stage: str(f, "stage"),
    monthly_value: num(f, "monthly_value"), probability: num(f, "probability"), expected_close: str(f, "expected_close") || null,
    lost_reason: str(f, "lost_reason") || null, notes: str(f, "notes"),
  } }, "Opportunity saved.", [...P, lead ? `/crm/leads/${lead}` : "/crm"]);
}

export async function convertLead(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const res = await runRpc<{ customer_id: string }>("convert_lead", { p_lead: str(f, "lead_id"), p: {
    name: str(f, "name") || null, customer_type: str(f, "customer_type") || null, phone: str(f, "phone") || null,
    credit_limit: num(f, "credit_limit"), payment_terms_days: num(f, "payment_terms_days"),
  } }, "Customer created.", [...P, "/customers"]);
  if (!res.ok) return res;
  redirect(`/customers/${res.data!.customer_id}`);
}

export async function saveSegment(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const rules: Record<string, unknown> = {
    customer_types: list(f, "customer_types"), route_ids: list(f, "route_ids"), sales_rep_ids: list(f, "sales_rep_ids"), bottle_models: list(f, "bottle_models"),
    cities: str(f, "cities").split(",").map((x) => x.trim()).filter(Boolean),
  };
  for (const k of ["min_days_since_order", "max_days_since_order", "min_monthly_sales"]) if (str(f, k)) rules[k] = Number(str(f, k));
  if (str(f, "has_overdue")) rules.has_overdue = str(f, "has_overdue") === "yes";
  if (str(f, "created_after")) rules.created_after = str(f, "created_after");
  return runRpc<{ customers: number }>("save_segment", { p_id: str(f, "id") || null, p_name: str(f, "name"), p_description: str(f, "description"), p_rules: rules },
    (d) => `Saved — ${d.customers} customer(s) match today.`, ["/crm/segments", "/crm/campaigns", "/crm/promotions"]);
}

export async function savePromotion(_p: ActionResult, f: FormData): Promise<ActionResult> {
  return runRpc("save_promotion", { p_id: str(f, "id") || null, p: {
    code: str(f, "code"), name: str(f, "name"), kind: str(f, "kind"), value: num(f, "value"), buy_qty: num(f, "buy_qty"), product_id: str(f, "product_id") || null,
    customer_types: list(f, "customer_types"), segment_id: str(f, "segment_id") || null, price_list_id: str(f, "price_list_id") || null,
    min_qty: num(f, "min_qty"), start_date: str(f, "start_date"), end_date: str(f, "end_date"), notes: str(f, "notes"),
  } }, "Promotion saved as a draft.", ["/crm/promotions"]);
}

export async function activatePromotion(_p: ActionResult, f: FormData): Promise<ActionResult> {
  return runRpcOrApproval("activate_promotion", { p_id: str(f, "promotion_id"), p_reason: str(f, "reason") || null }, "Promotion is on — it applies to new orders.",
    ["/crm/promotions"], str(f, "reason") || null);
}

export async function endPromotion(_p: ActionResult, f: FormData): Promise<ActionResult> {
  return runRpc("end_promotion", { p_id: str(f, "promotion_id"), p_reason: str(f, "reason") || null }, "Promotion ended.", ["/crm/promotions"]);
}

export async function saveCampaign(_p: ActionResult, f: FormData): Promise<ActionResult> {
  return runRpc("save_campaign", { p_id: str(f, "id") || null, p: {
    code: str(f, "code"), name: str(f, "name"), channel: str(f, "channel"), objective: str(f, "objective"), segment_id: str(f, "segment_id") || null,
    promotion_id: str(f, "promotion_id") || null, start_date: str(f, "start_date") || null, end_date: str(f, "end_date") || null,
    budget: num(f, "budget"), spent: num(f, "spent"), status: str(f, "status") || null, notes: str(f, "notes"),
  } }, "Campaign saved.", ["/crm/campaigns"]);
}

export async function sendCampaignMessage(_p: ActionResult, f: FormData): Promise<ActionResult> {
  return runRpc<{ queued: number; skipped: number }>("send_campaign_message", { p_campaign: str(f, "campaign_id"), p_body: str(f, "body") },
    (d) => `${d.queued} message(s) queued${d.skipped ? `, ${d.skipped} skipped (opted out or already sent)` : ""}.`, ["/crm/campaigns", "/messages"]);
}
