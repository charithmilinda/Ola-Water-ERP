"use server";

import { runRpc } from "@/lib/rpc";
import { str, type ActionResult } from "@/lib/actions";
import { num } from "@/lib/lines";

const P = (id?: string) => ["/fleet", "/expenses", "/", ...(id ? [`/fleet/${id}`] : [])];

function payment(f: FormData) {
  const method = str(f, "pay_method") || "cash";
  return { pay_method: method, money_account_id: method === "on_credit" ? null : str(f, `account_${method}`) || null, reference: str(f, "reference") };
}
const done = (d: { expense_status?: string | null }) =>
  d.expense_status === "pending_approval" ? " The cost is over the limit and waits for approval in Expenses." : "";

export async function recordFuel(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const v = str(f, "vehicle_id");
  return runRpc<{ expense_status: string }>("record_fuel", {
    p: { vehicle_id: v, date: str(f, "date") || null, litres: num(str(f, "litres")), amount: num(str(f, "amount")), odometer_km: num(str(f, "odometer_km")),
      station: str(f, "station"), driver_id: str(f, "driver_id") || null, ...payment(f) },
    p_client_txn_id: str(f, "client_txn_id"),
  }, (d) => `Fuel recorded.${done(d)}`, P(v));
}

export async function recordService(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const v = str(f, "vehicle_id");
  return runRpc<{ expense_status: string | null }>("record_vehicle_service", {
    p: { vehicle_id: v, date: str(f, "date") || null, kind: str(f, "kind"), description: str(f, "description"), odometer_km: num(str(f, "odometer_km")),
      cost: num(str(f, "cost")), vendor: str(f, "vendor"), next_due_km: num(str(f, "next_due_km")), next_due_date: str(f, "next_due_date") || null, ...payment(f) },
    p_client_txn_id: str(f, "client_txn_id"),
  }, (d) => `Service / repair recorded.${done(d)}`, P(v));
}

export async function recordDocument(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const v = str(f, "vehicle_id");
  return runRpc("record_vehicle_document", {
    p: { vehicle_id: v, doc_type: str(f, "doc_type"), doc_no: str(f, "doc_no"), provider: str(f, "provider"), issued_on: str(f, "issued_on") || null,
      expires_on: str(f, "expires_on"), cost: num(str(f, "cost")), notes: str(f, "notes"), ...payment(f) },
    p_client_txn_id: str(f, "client_txn_id"),
  }, "Document recorded.", P(v));
}

export async function saveVehicleDetails(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const v = str(f, "vehicle_id");
  return runRpc("save_vehicle_details", { p_vehicle: v, p: {
    make: str(f, "make"), model: str(f, "model"), year_made: num(str(f, "year_made")), fuel_type: str(f, "fuel_type") || null,
    assigned_driver_id: str(f, "assigned_driver_id") || null, service_interval_km: num(str(f, "service_interval_km")),
    service_interval_days: num(str(f, "service_interval_days")), odometer_km: num(str(f, "odometer_km")), last_service_km: num(str(f, "last_service_km")),
    last_service_date: str(f, "last_service_date") || null }, p_reason: str(f, "reason") || null }, "Vehicle details saved.", P(v));
}
