"use client";

import { useEffect, useRef } from "react";
import "leaflet/dist/leaflet.css";

export type MapPoint = { lat: number; lng: number; label: string; seq?: number | string; tone?: "start" | "done" | "next" };

/**
 * OpenStreetMap map (free, no key) with numbered stops joined in visiting order.
 * Map data © OpenStreetMap contributors.
 */
export function StopMap({ points, height = 360, closeLoop = false }: { points: MapPoint[]; height?: number; closeLoop?: boolean }) {
  const el = useRef<HTMLDivElement>(null);
  const key = JSON.stringify(points);
  useEffect(() => {
    let map: import("leaflet").Map | null = null;
    let cancelled = false;
    (async () => {
      const L = (await import("leaflet")).default;
      if (cancelled || !el.current || points.length === 0) return;
      map = L.map(el.current, { scrollWheelZoom: false });
      L.tileLayer("https://tile.openstreetmap.org/{z}/{x}/{y}.png", {
        maxZoom: 19, attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors',
      }).addTo(map);
      const ll = points.map((p) => [p.lat, p.lng] as [number, number]);
      L.polyline(closeLoop && ll.length > 1 ? [...ll, ll[0]] : ll, { color: "#1868d6", weight: 3, opacity: 0.7 }).addTo(map);
      points.forEach((p) => {
        const bg = p.tone === "start" ? "#0b1f3a" : p.tone === "done" ? "#94a3b8" : "#1868d6";
        const icon = L.divIcon({
          className: "",
          html: `<div style="background:${bg};color:#fff;border:2px solid #fff;border-radius:9999px;width:26px;height:26px;display:flex;align-items:center;justify-content:center;font:600 12px system-ui;box-shadow:0 1px 3px rgba(0,0,0,.35)">${p.seq ?? ""}</div>`,
          iconSize: [26, 26], iconAnchor: [13, 13],
        });
        L.marker([p.lat, p.lng], { icon, title: p.label }).bindTooltip(p.label).addTo(map!);
      });
      map.fitBounds(L.latLngBounds(ll), { padding: [30, 30], maxZoom: 15 });
    })();
    return () => { cancelled = true; map?.remove(); };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [key, closeLoop]);
  if (points.length === 0) return <p className="text-sm text-muted">No GPS locations to show.</p>;
  return <div ref={el} style={{ height }} className="z-0 w-full overflow-hidden rounded-lg ring-1 ring-line" />;
}
