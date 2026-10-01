"use client";

import { useState } from "react";
import { Menu, X } from "lucide-react";
import { Button } from "@/components/ui/button";
import { OlaWordmark } from "./logo";
import { SidebarNav, type ClientNavGroup } from "./sidebar-nav";

export function MobileNav({ groups }: { groups: ClientNavGroup[] }) {
  const [open, setOpen] = useState(false);
  return (
    <div className="lg:hidden">
      <Button variant="ghost" size="icon" aria-label="Open menu" onClick={() => setOpen(true)}>
        <Menu className="h-5 w-5" />
      </Button>
      {open && (
        <div className="fixed inset-0 z-50">
          <div className="absolute inset-0 bg-navy-900/40" onClick={() => setOpen(false)} aria-hidden />
          <div className="absolute inset-y-0 left-0 w-72 overflow-y-auto bg-white p-4 shadow-xl">
            <div className="mb-6 flex items-center justify-between">
              <OlaWordmark />
              <Button variant="ghost" size="icon" aria-label="Close menu" onClick={() => setOpen(false)}>
                <X className="h-5 w-5" />
              </Button>
            </div>
            <SidebarNav groups={groups} onNavigate={() => setOpen(false)} />
          </div>
        </div>
      )}
    </div>
  );
}
