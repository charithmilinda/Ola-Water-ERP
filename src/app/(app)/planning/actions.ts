"use server";

import { runRpc } from "@/lib/rpc";
import { str, type ActionResult } from "@/lib/actions";

const ids = (f: FormData) => {
  try { const v = JSON.parse(str(f, "order")); return Array.isArray(v) ? (v as string[]) : []; } catch { return []; }
};

export async function applyRunOrder(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const run = str(f, "run_id");
  return runRpc<number>("apply_run_order", { p_run: run, p_order: ids(f), p_reason: str(f, "reason") || null },
    (n) => `New order saved for ${n} stop(s). The driver's phone picks it up when it next syncs.`, [`/dispatch/${run}`]);
}

export async function applyRouteSequence(_p: ActionResult, f: FormData): Promise<ActionResult> {
  return runRpc<number>("apply_route_sequence", { p_route: str(f, "route_id"), p_customers: ids(f) },
    (n) => `Route order saved for ${n} customer(s). New runs on this route use it.`, ["/planning", "/routes"]);
}

export async function setWarehouseGps(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const lat = Number(str(f, "lat")); const lng = Number(str(f, "lng"));
  if (!str(f, "lat") || !str(f, "lng")) return { ok: false, message: "No location yet — allow location on this device, or type the numbers from Google Maps." };
  return runRpc("set_location_gps", { p_location: str(f, "location_id"), p_lat: lat, p_lng: lng }, "Location saved.", ["/planning"]);
}
