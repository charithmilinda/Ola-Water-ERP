"use client";

import { useState, useTransition } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { Bell, CheckCheck } from "lucide-react";
import { markNotificationsRead } from "@/app/notifications/actions";
import { cn } from "@/lib/cn";

export type NotificationItem = {
  id: string; type_code: string; title: string; body: string | null; href: string | null; severity: string; created_at: string; read_at: string | null;
};

function ago(iso: string) {
  const mins = Math.max(0, Math.round((Date.now() - new Date(iso).getTime()) / 60000));
  if (mins < 1) return "just now";
  if (mins < 60) return `${mins} min ago`;
  const h = Math.round(mins / 60);
  if (h < 24) return `${h} h ago`;
  return `${Math.round(h / 24)} d ago`;
}

export function NotificationBell({ unread, items }: { unread: number; items: NotificationItem[] }) {
  const [open, setOpen] = useState(false);
  const [pending, start] = useTransition();
  const router = useRouter();
  const go = (n: NotificationItem) => {
    setOpen(false);
    start(async () => {
      if (!n.read_at) await markNotificationsRead([n.id]);
      if (n.href) router.push(n.href);
    });
  };
  return (
    <div className="relative">
      <button type="button" onClick={() => setOpen((o) => !o)} aria-label={`Notifications${unread ? ` (${unread} unread)` : ""}`}
        className="relative flex h-11 w-11 items-center justify-center rounded-lg text-navy-800 hover:bg-ola-50">
        <Bell className="h-5 w-5" />
        {unread > 0 && (
          <span className="absolute right-0.5 top-0.5 flex h-5 min-w-5 items-center justify-center rounded-full bg-red-600 px-1 text-[11px] font-semibold text-white">
            {unread > 99 ? "99+" : unread}
          </span>
        )}
      </button>
      {open && (
        <>
          <button type="button" aria-label="Close notifications" className="fixed inset-0 z-30 cursor-default" onClick={() => setOpen(false)} />
          <div className="fixed inset-x-2 top-14 z-40 rounded-xl border border-line bg-white shadow-lg sm:absolute sm:inset-x-auto sm:right-0 sm:top-full sm:mt-2 sm:w-96">
            <div className="flex items-center justify-between border-b border-line px-4 py-3">
              <p className="text-sm font-semibold text-navy-900">Notifications</p>
              {unread > 0 && (
                <button type="button" disabled={pending} onClick={() => start(async () => { await markNotificationsRead(null); })}
                  className="flex items-center gap-1 text-xs font-medium text-ola-700 hover:underline">
                  <CheckCheck className="h-3.5 w-3.5" /> Mark all read
                </button>
              )}
            </div>
            <ul className="max-h-[65dvh] divide-y divide-line overflow-y-auto">
              {items.length === 0 && <li className="px-4 py-6 text-center text-sm text-muted">Nothing new.</li>}
              {items.map((n) => (
                <li key={n.id}>
                  <button type="button" onClick={() => go(n)} className={cn("block w-full px-4 py-3 text-left hover:bg-ola-50/60", !n.read_at && "bg-ola-50/40")}>
                    <span className="flex items-start gap-2">
                      <span className={cn("mt-1.5 h-2 w-2 shrink-0 rounded-full",
                        n.read_at ? "bg-transparent" : n.severity === "critical" ? "bg-red-600" : n.severity === "warning" ? "bg-amber-500" : "bg-ola-600")} />
                      <span className="min-w-0">
                        <span className="block text-sm font-medium text-navy-900">{n.title}</span>
                        {n.body && <span className="line-clamp-2 block text-xs text-muted">{n.body}</span>}
                        <span className="block text-[11px] text-muted">{ago(n.created_at)}</span>
                      </span>
                    </span>
                  </button>
                </li>
              ))}
            </ul>
            <div className="border-t border-line px-4 py-2 text-right">
              <Link href="/approvals" onClick={() => setOpen(false)} className="text-xs font-medium text-ola-700 hover:underline">Approvals inbox</Link>
            </div>
          </div>
        </>
      )}
    </div>
  );
}
