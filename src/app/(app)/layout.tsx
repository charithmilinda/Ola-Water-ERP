import { getAccess } from "@/lib/access";
import { visibleNav } from "@/lib/nav";
import { OlaWordmark } from "@/components/layout/logo";
import { SidebarNav, type ClientNavGroup } from "@/components/layout/sidebar-nav";
import { MobileNav } from "@/components/layout/mobile-nav";
import { UserMenu } from "@/components/layout/user-menu";

export const dynamic = "force-dynamic";

export default async function AppLayout({ children }: { children: React.ReactNode }) {
  const access = await getAccess();
  const groups: ClientNavGroup[] = visibleNav(access.is_super_admin, access.permissions);

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
          <UserMenu access={access} />
        </header>
        <main className="mx-auto w-full max-w-[1400px] flex-1 px-4 py-6 sm:px-6 lg:px-8">{children}</main>
      </div>
    </div>
  );
}
