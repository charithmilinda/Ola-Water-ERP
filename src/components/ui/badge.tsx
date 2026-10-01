import { cn } from "@/lib/cn";

const tones = {
  neutral: "bg-slate-100 text-slate-700 ring-slate-200",
  blue: "bg-ola-50 text-ola-800 ring-ola-200",
  green: "bg-emerald-50 text-emerald-800 ring-emerald-200",
  amber: "bg-amber-50 text-amber-800 ring-amber-200",
  red: "bg-red-50 text-red-800 ring-red-200",
  navy: "bg-navy-900 text-white ring-navy-900",
} as const;

export type BadgeTone = keyof typeof tones;

/** Status badge: always text + colour, never colour alone. */
export function Badge({ tone = "neutral", className, ...props }: React.HTMLAttributes<HTMLSpanElement> & { tone?: BadgeTone }) {
  return (
    <span
      className={cn("inline-flex items-center gap-1 rounded-full px-2 py-0.5 text-xs font-medium ring-1 ring-inset whitespace-nowrap", tones[tone], className)}
      {...props}
    />
  );
}
