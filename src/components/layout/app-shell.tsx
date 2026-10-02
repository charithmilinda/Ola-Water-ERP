import type { Access } from "@/lib/access";
import { OlaWordmark } from "./logo";
import { SidebarNav, type ClientNavGroup } from "./sidebar-nav";
import { MobileNav } from "./mobile-nav";
import { UserMenu } from "./user-menu";
import { NotificationBell, type NotificationItem } from "./notification-bell";

/** The page frame: sidebar on large screens, top bar with a slide-in menu on phones and tablets. */
export function AppShell({ access, groups, notifications, children }: {
  access: Access; groups: ClientNavGroup[]; notifications: { unread: number; items: NotificationItem[] }; children: React.ReactNode;
}) {
  return (
    <div className="flex min-h-dvh">
      <aside className="no-print sticky top-0 hidden h-dvh w-64 shrink-0 flex-col border-r border-line bg-white lg:flex">
        <div className="px-5 py-5">
          <OlaWordmark />
        </div>
        <div className="flex-1 overflow-y-auto overscroll-contain px-3 pb-6">
          <SidebarNav groups={groups} />
        </div>
      </aside>
      <div className="flex min-w-0 flex-1 flex-col">
        {/* solid background: a blur here would trap the phone menu and pop-ups inside the bar */}
        <header className="no-print sticky top-0 z-30 flex h-14 items-center justify-between gap-2 border-b border-line bg-white px-2 sm:h-16 sm:px-6">
          <div className="flex min-w-0 items-center gap-1">
            <MobileNav groups={groups} userName={access.full_name} />
            <div className="min-w-0 lg:hidden">
              <OlaWordmark />
            </div>
          </div>
          <div className="flex shrink-0 items-center gap-1">
            <NotificationBell unread={notifications.unread} items={notifications.items} />
            <UserMenu access={access} />
          </div>
        </header>
        <main className="mx-auto w-full max-w-[1400px] flex-1 px-3 py-4 sm:px-6 sm:py-6 lg:px-8">{children}</main>
      </div>
    </div>
  );
}
