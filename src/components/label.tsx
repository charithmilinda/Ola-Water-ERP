import { barcodeSvg, LABEL_SIZES, type Symbology } from "@/lib/barcode";

/** One physical label. Sized in millimetres so it prints 1:1 on a label printer. */
export function Label({
  value,
  symbology,
  size,
  caption,
}: {
  value: string;
  symbology: Symbology;
  size: keyof typeof LABEL_SIZES;
  caption: string;
}) {
  const { w, h } = LABEL_SIZES[size];
  const svg = barcodeSvg(value, symbology);
  const linear = symbology === "code128";
  return (
    <div
      className="label box-border flex overflow-hidden bg-white text-black"
      style={{
        width: `${w}mm`,
        height: `${h}mm`,
        padding: "1.5mm",
        flexDirection: linear ? "column" : "row",
        alignItems: "center",
        gap: "1.5mm",
      }}
    >
      <div
        className="[&>svg]:h-full [&>svg]:w-full"
        style={linear ? { width: "100%", height: `${h * 0.5}mm` } : { width: `${h - 3}mm`, height: `${h - 3}mm`, flex: "none" }}
        dangerouslySetInnerHTML={{ __html: svg }}
      />
      <div style={{ minWidth: 0, textAlign: linear ? "center" : "left", lineHeight: 1.15 }}>
        <div style={{ fontSize: "1.9mm", fontWeight: 700, letterSpacing: "0.04em" }}>{caption}</div>
        <div style={{ fontFamily: "ui-monospace, Menlo, monospace", fontSize: w <= 30 ? "1.9mm" : "2.4mm", fontWeight: 600, wordBreak: "break-all" }}>
          {value}
        </div>
      </div>
    </div>
  );
}

export function captionFor(series: string): string {
  if (series.startsWith("EXT-")) return `EXT TAG · ${series.slice(4)}`;
  if (series === "OLA-CRT") return "OLA WATER · CRATE";
  return "OLA WATER";
}
