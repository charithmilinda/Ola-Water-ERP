import { todayISO } from "@/lib/format";
import { MONTHS } from "@/lib/labels";

/** "YYYY-MM" from the URL, or this month. */
export function pickMonth(raw?: string) {
  const m = raw && /^\d{4}-(0[1-9]|1[0-2])$/.test(raw) ? raw : todayISO().slice(0, 7);
  const [y, mo] = m.split("-").map(Number);
  return { key: m, year: y, month: mo, label: `${MONTHS[mo - 1]} ${y}` };
}

export function pct(actual: number, target: number) {
  return target > 0 ? Math.round((actual / target) * 100) : null;
}
