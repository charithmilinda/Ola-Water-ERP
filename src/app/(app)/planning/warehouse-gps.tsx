"use client";

import { useState } from "react";
import { LocateFixed } from "lucide-react";
import { ActionForm } from "@/components/ui/action-form";
import { SubmitButton } from "@/components/ui/submit-button";
import { Input } from "@/components/ui/field";
import type { ActionResult } from "@/lib/actions";

/** Set a location's GPS: press "Use this device's location" while standing there, or type it from Google Maps. */
export function WarehouseGps({ locationId, lat, lng, action }: {
  locationId: string; lat: number | null; lng: number | null; action: (p: ActionResult, f: FormData) => Promise<ActionResult>;
}) {
  const [la, setLa] = useState(lat !== null ? String(lat) : "");
  const [ln, setLn] = useState(lng !== null ? String(lng) : "");
  const [msg, setMsg] = useState("");
  const locate = () => {
    if (!("geolocation" in navigator)) return setMsg("This device has no GPS.");
    setMsg("Finding your location…");
    navigator.geolocation.getCurrentPosition(
      (p) => { setLa(p.coords.latitude.toFixed(6)); setLn(p.coords.longitude.toFixed(6)); setMsg(`Found (±${Math.round(p.coords.accuracy)} m) — press Save.`); },
      () => setMsg("Location not allowed in this browser."), { enableHighAccuracy: true, timeout: 15000 });
  };
  return (
    <ActionForm action={action} className="flex flex-wrap items-end gap-2">
      <input type="hidden" name="location_id" value={locationId} />
      <label className="text-xs text-muted">Latitude<Input name="lat" value={la} onChange={(e) => setLa(e.target.value)} inputMode="decimal" className="mt-1 h-9 w-36" placeholder="6.9271" /></label>
      <label className="text-xs text-muted">Longitude<Input name="lng" value={ln} onChange={(e) => setLn(e.target.value)} inputMode="decimal" className="mt-1 h-9 w-36" placeholder="79.8612" /></label>
      <button type="button" onClick={locate} className="flex h-9 items-center gap-1 rounded-lg px-3 text-sm font-medium text-ola-700 ring-1 ring-line hover:bg-ola-50">
        <LocateFixed className="h-4 w-4" /> Use this device&apos;s location</button>
      <SubmitButton>Save</SubmitButton>
      {msg && <span className="w-full text-xs text-muted">{msg}</span>}
    </ActionForm>
  );
}
