"use client";

import { useEffect, useRef } from "react";

/** Finger signature. Calls onChange with a small PNG data URL (or "" when cleared). */
export function SignaturePad({ onChange }: { onChange: (dataUrl: string) => void }) {
  const canvas = useRef<HTMLCanvasElement>(null);
  const drawing = useRef(false);
  const dirty = useRef(false);

  useEffect(() => {
    const c = canvas.current!;
    const ratio = Math.min(window.devicePixelRatio || 1, 2);
    c.width = c.offsetWidth * ratio;
    c.height = c.offsetHeight * ratio;
    const g = c.getContext("2d")!;
    g.scale(ratio, ratio);
    g.lineWidth = 2.2;
    g.lineCap = "round";
    g.strokeStyle = "#0b1f3a";
  }, []);

  const pos = (e: React.PointerEvent) => {
    const r = canvas.current!.getBoundingClientRect();
    return { x: e.clientX - r.left, y: e.clientY - r.top };
  };

  return (
    <div>
      <canvas
        ref={canvas}
        className="h-40 w-full touch-none rounded-xl border-2 border-dashed border-line bg-white"
        onPointerDown={(e) => { drawing.current = true; const p = pos(e); const g = canvas.current!.getContext("2d")!; g.beginPath(); g.moveTo(p.x, p.y); canvas.current!.setPointerCapture(e.pointerId); }}
        onPointerMove={(e) => { if (!drawing.current) return; const p = pos(e); const g = canvas.current!.getContext("2d")!; g.lineTo(p.x, p.y); g.stroke(); dirty.current = true; }}
        onPointerUp={() => {
          drawing.current = false;
          if (!dirty.current) return;
          // shrink to keep the stored signature small
          const src = canvas.current!;
          const out = document.createElement("canvas");
          out.width = 480;
          out.height = Math.round((480 * src.height) / src.width);
          const g = out.getContext("2d")!;
          g.fillStyle = "#fff";
          g.fillRect(0, 0, out.width, out.height);
          g.drawImage(src, 0, 0, out.width, out.height);
          onChange(out.toDataURL("image/jpeg", 0.7));
        }}
      />
      <div className="mt-1 flex justify-between text-xs text-muted">
        <span>Customer signs with a finger</span>
        <button type="button" className="font-medium text-ola-700" onClick={() => {
          const c = canvas.current!;
          c.getContext("2d")!.clearRect(0, 0, c.width, c.height);
          dirty.current = false;
          onChange("");
        }}>Clear</button>
      </div>
    </div>
  );
}

/** Resize a photo on the phone before storing/uploading it. */
export async function compressPhoto(file: File, max = 1024, quality = 0.6): Promise<string> {
  const url = URL.createObjectURL(file);
  try {
    const img = await new Promise<HTMLImageElement>((res, rej) => { const i = new Image(); i.onload = () => res(i); i.onerror = rej; i.src = url; });
    const scale = Math.min(1, max / Math.max(img.width, img.height));
    const c = document.createElement("canvas");
    c.width = Math.round(img.width * scale);
    c.height = Math.round(img.height * scale);
    c.getContext("2d")!.drawImage(img, 0, 0, c.width, c.height);
    return c.toDataURL("image/jpeg", quality);
  } finally {
    URL.revokeObjectURL(url);
  }
}
