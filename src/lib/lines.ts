export type Line = { item_id: string } & Record<string, string>;

/** Read the JSON rows posted by the LineEditor component. */
export function parseLines(raw: FormDataEntryValue | null): Line[] {
  if (typeof raw !== "string" || !raw) return [];
  try {
    const v = JSON.parse(raw);
    return Array.isArray(v) ? (v as Line[]).filter((r) => r && typeof r.item_id === "string" && r.item_id) : [];
  } catch {
    return [];
  }
}

/** A number from a form string, or null when left empty. */
export function num(v: string | undefined | null): number | null {
  if (v === undefined || v === null || String(v).trim() === "") return null;
  const n = Number(v);
  return Number.isFinite(n) ? n : null;
}
