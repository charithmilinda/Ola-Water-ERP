"use client";

import { useEffect, useState } from "react";
import { createPortal } from "react-dom";
import { usePathname } from "next/navigation";
import { Menu, X } from "lucide-react";
import { OlaWordmark } from "./logo";
import { SidebarNav, type ClientNavGroup } from "./sidebar-nav";

/** Menu button and slide-in menu for phones and tablets. */
export function MobileNav({ groups, userName }: { groups: ClientNavGroup[]; userName?: string }) {
  const [open, setOpen] = useState(false);
  const [mounted, setMounted] = useState(false);
  const pathname = usePathname();

  useEffect(() => setMounted(true), []);
  useEffect(() => setOpen(false), [pathname]);
  useEffect(() => {
    if (!open) return;
    const prev = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && setOpen(false);
    window.addEventListener("keydown", onKey);
    return () => { document.body.style.overflow = prev; window.removeEventListener("keydown", onKey); };
  }, [open]);

  return (
    <div className="lg:hidden">
      <button type="button" aria-label="Open menu" aria-expanded={open} onClick={() => setOpen(true)}
        className="flex h-11 w-11 items-center justify-center rounded-lg text-navy-800 hover:bg-ola-50 active:bg-ola-100">
        <Menu className="h-6 w-6" />
      </button>
      {mounted && createPortal(
        <div className={`fixed inset-0 z-[60] lg:hidden ${open ? "" : "pointer-events-none"}`} aria-hidden={!open}>
          <div className={`absolute inset-0 bg-navy-900/50 transition-opacity duration-200 ${open ? "opacity-100" : "opacity-0"}`} onClick={() => setOpen(false)} />
          <div role="dialog" aria-modal="true" aria-label="Menu"
            className={`absolute inset-y-0 left-0 flex w-[85vw] max-w-80 flex-col bg-white shadow-2xl transition-transform duration-200 ease-out ${open ? "translate-x-0" : "-translate-x-full"}`}>
            <div className="flex h-14 shrink-0 items-center justify-between border-b border-line px-4">
              <OlaWordmark />
              <button type="button" aria-label="Close menu" onClick={() => setOpen(false)}
                className="flex h-11 w-11 items-center justify-center rounded-lg text-navy-800 hover:bg-ola-50">
                <X className="h-6 w-6" />
              </button>
            </div>
            <div className="flex-1 overflow-y-auto overscroll-contain px-3 py-4 [padding-bottom:max(1rem,env(safe-area-inset-bottom))]">
              <SidebarNav groups={groups} onNavigate={() => setOpen(false)} large />
            </div>
            {userName && <p className="shrink-0 border-t border-line px-5 py-3 text-xs text-muted">Signed in as {userName}</p>}
          </div>
        </div>,
        document.body,
      )}
    </div>
  );
}
