"use client";

import { useEffect, useState } from "react";
import { LocateFixed } from "lucide-react";

/** Hidden lat/lng/accuracy inputs filled from the phone's GPS. */
export function GpsFields() {
  const [pos, setPos] = useState<{ lat: number; lng: number; acc: number } | null>(null);
  const [msg, setMsg] = useState("Finding your location…");
  const locate = () => {
    if (!("geolocation" in navigator)) { setMsg("This device has no GPS — the visit is saved without location."); return; }
    setMsg("Finding your location…");
    navigator.geolocation.getCurrentPosition(
      (p) => { setPos({ lat: Number(p.coords.latitude.toFixed(6)), lng: Number(p.coords.longitude.toFixed(6)), acc: Math.round(p.coords.accuracy) }); setMsg(""); },
      () => setMsg("Location not allowed — allow it in the browser to record where you checked in."),
      { enableHighAccuracy: true, timeout: 15000, maximumAge: 60000 },
    );
  };
  useEffect(locate, []);
  return (
    <div className="flex items-center gap-2 text-sm">
      <input type="hidden" name="lat" value={pos?.lat ?? ""} />
      <input type="hidden" name="lng" value={pos?.lng ?? ""} />
      <input type="hidden" name="accuracy" value={pos?.acc ?? ""} />
      <LocateFixed className={`h-4 w-4 ${pos ? "text-emerald-600" : "text-muted"}`} />
      <span className={pos ? "text-emerald-700" : "text-muted"}>{pos ? `Location found (±${pos.acc} m)` : msg}</span>
      {!pos && <button type="button" onClick={locate} className="text-xs font-semibold text-ola-700">Try again</button>}
    </div>
  );
}
