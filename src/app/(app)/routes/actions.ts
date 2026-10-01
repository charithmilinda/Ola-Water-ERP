"use server";

import { runRpc } from "@/lib/rpc";
import { str, type ActionResult } from "@/lib/actions";

export async function saveRoute(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const id = str(f, "id") || null;
  return runRpc("save_route", {
    p_id: id,
    p: { code: str(f, "code"), name: str(f, "name"), area: str(f, "area"), default_vehicle_id: str(f, "default_vehicle_id"),
         default_driver_id: str(f, "default_driver_id"), notes: str(f, "notes"), is_active: id ? f.get("is_active") === "on" : true },
    p_reason: str(f, "reason") || (id ? null : "New route"),
  }, "Route saved.", ["/routes"]);
}

export async function saveVehicle(_p: ActionResult, f: FormData): Promise<ActionResult> {
  const id = str(f, "id") || null;
  return runRpc("save_vehicle", {
    p_id: id,
    p: { registration_no: str(f, "registration_no"), name: str(f, "name"), vehicle_type: str(f, "vehicle_type"),
         capacity_19l: str(f, "capacity_19l"), notes: str(f, "notes"), is_active: id ? f.get("is_active") === "on" : true },
    p_reason: str(f, "reason") || (id ? null : "New vehicle"),
  }, "Vehicle saved.", ["/routes"]);
}
