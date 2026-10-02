"use client";

import { useState } from "react";
import Link from "next/link";
import { usePathname } from "next/navigation";
import { ChevronDown } from "lucide-react";
import { NAV_ICONS, type NavIconName } from "@/lib/nav-icons";
import { cn } from "@/lib/cn";

export type ClientNavGroup = { label: string; items: { href: string; label: string; icon: NavIconName }[] };

/**
 * Navigation list. On large screens every group is open; in the phone menu
 * (`large`) groups fold, with the current section and Overview open.
 */
export function SidebarNav({ groups, onNavigate, large }: { groups: ClientNavGroup[]; onNavigate?: () => void; large?: boolean }) {
  const pathname = usePathname();
  // The most specific matching link is the active one (e.g. /bottles/external over /bottles)
  const all = groups.flatMap((g) => g.items.map((i) => i.href));
  const activeHref = all
    .filter((h) => (h === "/" ? pathname === "/" : pathname === h || pathname.startsWith(`${h}/`)))
    .sort((a, b) => b.length - a.length)[0];
  const activeGroup = groups.find((g) => g.items.some((i) => i.href === activeHref))?.label;
  const [open, setOpen] = useState<Record<string, boolean>>(() =>
    Object.fromEntries(groups.map((g) => [g.label, !large || g.label === activeGroup || g.label === "Overview" || groups.length <= 3])));

  return (
    <nav aria-label="Main" className={large ? "space-y-1" : "space-y-6"}>
      {groups.map((g) => {
        const isOpen = open[g.label] ?? true;
        const list = (
          <ul className={cn("space-y-0.5", large && "pb-2")}>
            {g.items.map((item) => {
              const active = item.href === activeHref;
              const Icon = NAV_ICONS[item.icon] ?? NAV_ICONS.Circle;
              return (
                <li key={item.href}>
                  <Link
                    href={item.href}
                    onClick={onNavigate}
                    aria-current={active ? "page" : undefined}
                    className={cn(
                      "flex items-center gap-3 rounded-lg px-3 text-sm font-medium transition-colors",
                      large ? "min-h-11 py-2.5 text-[15px]" : "py-2",
                      active ? "bg-ola-600 text-white shadow-sm" : "text-navy-800 hover:bg-ola-50 active:bg-ola-100",
                    )}
                  >
                    <Icon className="h-4 w-4 shrink-0" aria-hidden />
                    {item.label}
                  </Link>
                </li>
              );
            })}
          </ul>
        );
        if (!large) {
          return (
            <div key={g.label}>
              <p className="mb-1.5 px-3 text-[11px] font-semibold uppercase tracking-wider text-muted">{g.label}</p>
              {list}
            </div>
          );
        }
        return (
          <div key={g.label} className="border-b border-line/70 last:border-0">
            <button type="button" aria-expanded={isOpen} onClick={() => setOpen((o) => ({ ...o, [g.label]: !isOpen }))}
              className="flex min-h-11 w-full items-center justify-between rounded-lg px-3 text-left text-xs font-semibold uppercase tracking-wider text-muted hover:bg-surface">
              <span>{g.label}{!isOpen && g.label === activeGroup && <span className="ml-2 inline-block h-1.5 w-1.5 rounded-full bg-ola-600 align-middle" />}</span>
              <ChevronDown className={cn("h-4 w-4 transition-transform", isOpen && "rotate-180")} aria-hidden />
            </button>
            {isOpen && list}
          </div>
        );
      })}
    </nav>
  );
}
