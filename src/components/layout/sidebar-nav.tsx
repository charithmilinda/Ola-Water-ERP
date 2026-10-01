"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { NAV_ICONS, type NavIconName } from "@/lib/nav-icons";
import { cn } from "@/lib/cn";

export type ClientNavGroup = { label: string; items: { href: string; label: string; icon: NavIconName }[] };

export function SidebarNav({ groups, onNavigate }: { groups: ClientNavGroup[]; onNavigate?: () => void }) {
  const pathname = usePathname();
  // The most specific matching link is the active one (e.g. /bottles/external over /bottles)
  const all = groups.flatMap((g) => g.items.map((i) => i.href));
  const activeHref = all
    .filter((h) => (h === "/" ? pathname === "/" : pathname === h || pathname.startsWith(`${h}/`)))
    .sort((a, b) => b.length - a.length)[0];
  return (
    <nav aria-label="Main" className="space-y-6">
      {groups.map((g) => (
        <div key={g.label}>
          <p className="mb-1.5 px-3 text-[11px] font-semibold uppercase tracking-wider text-muted">{g.label}</p>
          <ul className="space-y-0.5">
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
                      "flex items-center gap-3 rounded-lg px-3 py-2 text-sm font-medium transition-colors",
                      active ? "bg-ola-600 text-white shadow-sm" : "text-navy-800 hover:bg-ola-50",
                    )}
                  >
                    <Icon className="h-4 w-4 shrink-0" aria-hidden />
                    {item.label}
                  </Link>
                </li>
              );
            })}
          </ul>
        </div>
      ))}
    </nav>
  );
}
