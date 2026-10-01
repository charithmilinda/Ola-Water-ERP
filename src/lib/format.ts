// Sri Lankan formatting helpers (Asia/Colombo, LKR, DD/MM/YYYY)

export const TIME_ZONE = "Asia/Colombo";

export function formatLKR(value: number | string | null | undefined): string {
  if (value === null || value === undefined || value === "") return "—";
  const n = typeof value === "string" ? Number(value) : value;
  return `Rs. ${n.toLocaleString("en-LK", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
}

export function formatDate(value: string | Date | null | undefined): string {
  if (!value) return "—";
  const d = typeof value === "string" ? new Date(value.length === 10 ? `${value}T00:00:00+05:30` : value) : value;
  return new Intl.DateTimeFormat("en-GB", { timeZone: TIME_ZONE, day: "2-digit", month: "2-digit", year: "numeric" }).format(d);
}

export function formatDateTime(value: string | Date | null | undefined): string {
  if (!value) return "—";
  const d = typeof value === "string" ? new Date(value) : value;
  return new Intl.DateTimeFormat("en-GB", {
    timeZone: TIME_ZONE,
    day: "2-digit",
    month: "2-digit",
    year: "numeric",
    hour: "numeric",
    minute: "2-digit",
    hour12: true,
  }).format(d);
}

/** Today's date in Colombo as YYYY-MM-DD */
export function todayISO(): string {
  return new Intl.DateTimeFormat("en-CA", { timeZone: TIME_ZONE }).format(new Date());
}

/** +94771234567 -> 077 123 4567 */
export function formatPhone(e164: string | null | undefined): string {
  if (!e164) return "—";
  const m = e164.match(/^\+94(\d{2})(\d{3})(\d{4})$/);
  return m ? `0${m[1]} ${m[2]} ${m[3]}` : e164;
}

/** 0771234567 / 077 123 4567 / +94771234567 -> +94771234567 (null if invalid) */
export function normalizeSriLankanPhone(input: string): string | null {
  const digits = input.replace(/[^\d+]/g, "");
  if (/^\+94\d{9}$/.test(digits)) return digits;
  if (/^0\d{9}$/.test(digits)) return `+94${digits.slice(1)}`;
  if (/^94\d{9}$/.test(digits)) return `+${digits}`;
  return null;
}

export function humanize(code: string | null | undefined): string {
  if (!code) return "—";
  return code.replace(/[._]/g, " ").replace(/\b\w/g, (c) => c.toUpperCase());
}

/** Quantities: whole numbers stay whole, materials show up to 3 decimals. */
export function formatQty(value: number | string | null | undefined): string {
  if (value === null || value === undefined || value === "") return "—";
  const n = typeof value === "string" ? Number(value) : value;
  return n.toLocaleString("en-LK", { maximumFractionDigits: 3 });
}
