import "server-only";
import bwipjs from "bwip-js/node";

export type Symbology = "qrcode" | "datamatrix" | "code128";

/** Render a barcode as an SVG string (server-side, no network). */
export function barcodeSvg(text: string, symbology: Symbology): string {
  if (symbology === "code128") {
    return bwipjs.toSVG({ bcid: "code128", text, height: 8, includetext: false, paddingwidth: 0, paddingheight: 0 });
  }
  return bwipjs.toSVG({
    bcid: symbology,
    text,
    // Highest QR error correction survives scuffs and water droplets on bottles
    ...(symbology === "qrcode" ? { eclevel: "H" } : {}),
    paddingwidth: 0,
    paddingheight: 0,
  });
}

export const LABEL_SIZES = {
  "50x25": { w: 50, h: 25 },
  "40x30": { w: 40, h: 30 },
  "30x20": { w: 30, h: 20 },
} as const;

export const PRINT_PART_SIZE = 250;

export function labelValue(series: string, n: number, padding: number) {
  return `${series}-${String(n).padStart(padding, "0")}`;
}
