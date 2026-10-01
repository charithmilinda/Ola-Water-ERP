"use client";

import { useEffect, useRef, useState } from "react";
import { Camera, CameraOff, Keyboard } from "lucide-react";

/**
 * Barcode / QR scanning:
 *  - phone camera (continuous, works on Android and iPhone via ZXing)
 *  - USB / Bluetooth scanners that type the code and press Enter
 *  - manual typing as a fallback
 */
export function Scanner({ onScan, label = "Scan bottles" }: { onScan: (code: string) => void; label?: string }) {
  const video = useRef<HTMLVideoElement>(null);
  const controls = useRef<{ stop: () => void } | null>(null);
  const last = useRef<{ code: string; at: number }>({ code: "", at: 0 });
  const [on, setOn] = useState(false);
  const [error, setError] = useState("");
  const [typed, setTyped] = useState("");

  const emit = (raw: string) => {
    const code = raw.trim().toUpperCase();
    if (!code) return;
    const now = Date.now();
    if (last.current.code === code && now - last.current.at < 2500) return; // same bottle still in view
    last.current = { code, at: now };
    beep();
    if (navigator.vibrate) navigator.vibrate(60);
    onScan(code);
  };

  useEffect(() => {
    if (!on) return;
    let cancelled = false;
    (async () => {
      try {
        const { BrowserMultiFormatReader } = await import("@zxing/browser");
        const reader = new BrowserMultiFormatReader();
        const c = await reader.decodeFromConstraints(
          { video: { facingMode: { ideal: "environment" }, width: { ideal: 1280 } } },
          video.current!,
          (result) => {
            if (result) emit(result.getText());
          },
        );
        if (cancelled) c.stop();
        else controls.current = c;
      } catch (e) {
        setError(e instanceof Error && /Permission|NotAllowed/i.test(e.name + e.message) ? "Camera permission was refused. Allow camera access in the browser settings." : "Camera could not start on this device.");
        setOn(false);
      }
    })();
    return () => {
      cancelled = true;
      controls.current?.stop();
      controls.current = null;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [on]);

  return (
    <div className="space-y-2">
      <div className="flex gap-2">
        <button type="button" onClick={() => { setError(""); setOn((v) => !v); }}
          className={`flex h-12 flex-1 items-center justify-center gap-2 rounded-xl font-semibold ${on ? "bg-navy-900 text-white" : "bg-ola-600 text-white"}`}>
          {on ? <CameraOff className="h-5 w-5" /> : <Camera className="h-5 w-5" />} {on ? "Stop camera" : label}
        </button>
      </div>
      {on && (
        <div className="relative overflow-hidden rounded-xl bg-black">
          <video ref={video} className="aspect-[4/3] w-full object-cover" muted playsInline />
          <div className="pointer-events-none absolute inset-8 rounded-lg border-2 border-white/70" />
        </div>
      )}
      {error && <p className="text-sm text-red-700">{error}</p>}
      <form onSubmit={(e) => { e.preventDefault(); emit(typed); setTyped(""); }} className="flex gap-2">
        <div className="relative flex-1">
          <Keyboard className="pointer-events-none absolute left-3 top-3.5 h-4 w-4 text-muted" />
          <input value={typed} onChange={(e) => setTyped(e.target.value)} placeholder="Scanner or type code + Enter"
            className="h-11 w-full rounded-xl border border-line pl-9 pr-3 font-mono text-sm uppercase" autoCapitalize="characters" autoCorrect="off" spellCheck={false} />
        </div>
        <button type="submit" className="h-11 rounded-xl border border-line px-4 text-sm font-medium">Add</button>
      </form>
    </div>
  );
}

let ctx: AudioContext | null = null;
function beep() {
  try {
    ctx = ctx ?? new AudioContext();
    const o = ctx.createOscillator();
    const g = ctx.createGain();
    o.frequency.value = 1400;
    g.gain.value = 0.08;
    o.connect(g).connect(ctx.destination);
    o.start();
    o.stop(ctx.currentTime + 0.08);
  } catch {
    // sound is optional
  }
}
