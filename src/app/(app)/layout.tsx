import { getAccess } from "@/lib/access";
import { visibleNav } from "@/lib/nav";
import { OlaWordmark } from "@/components/layout/logo";
import { SidebarNav, type ClientNavGroup } from "@/components/layout/sidebar-nav";
import { MobileNav } from "@/components/layout/mobile-nav";
import { UserMenu } from "@/components/layout/user-menu";
import { NotificationBell, type NotificationItem } from "@/components/layout/notification-bell";
import { after } from "next/server";
import { createClient } from "@/lib/supabase/server";
import { backgroundHousekeeping } from "@/lib/messaging/dispatch";

export const dynamic = "force-dynamic";

export default async function AppLayout({ children }: { children: React.ReactNode }) {
  const access = await getAccess();
  const groups: ClientNavGroup[] = visibleNav(access.is_super_admin, access.permissions, access.scoped.map((x) => x.permission));
  const supabase = await createClient();
  const { data: notes } = await supabase.rpc("my_notifications", { p_limit: 15 });
  const n = (notes ?? { unread: 0, items: [] }) as { unread: number; items: NotificationItem[] };
  // alert scan and message queue run after the page is sent (throttled)
  after(() => backgroundHousekeeping(supabase));

  return (
    <div className="flex min-h-dvh">
      <aside className="no-print sticky top-0 hidden h-dvh w-64 shrink-0 flex-col border-r border-line bg-white lg:flex">
        <div className="px-5 py-5">
          <OlaWordmark />
        </div>
        <div className="flex-1 overflow-y-auto px-3 pb-6">
          <SidebarNav groups={groups} />
        </div>
      </aside>
      <div className="flex min-w-0 flex-1 flex-col">
        <header className="no-print sticky top-0 z-30 flex h-16 items-center justify-between gap-3 border-b border-line bg-white/90 px-4 backdrop-blur sm:px-6">
          <div className="flex items-center gap-2">
            <MobileNav groups={groups} />
            <div className="lg:hidden">
              <OlaWordmark />
            </div>
          </div>
          <div className="flex items-center gap-1">
            <NotificationBell unread={n.unread} items={n.items} />
            <UserMenu access={access} />
          </div>
        </header>
        <main className="mx-auto w-full max-w-[1400px] flex-1 px-4 py-6 sm:px-6 lg:px-8">{children}</main>
      </div>
    </div>
  );
}
