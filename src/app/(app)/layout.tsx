import { after } from "next/server";
import { getAccess } from "@/lib/access";
import { visibleNav } from "@/lib/nav";
import { createClient } from "@/lib/supabase/server";
import { backgroundHousekeeping } from "@/lib/messaging/dispatch";
import { AppShell } from "@/components/layout/app-shell";
import type { ClientNavGroup } from "@/components/layout/sidebar-nav";
import type { NotificationItem } from "@/components/layout/notification-bell";

export const dynamic = "force-dynamic";

export default async function AppLayout({ children }: { children: React.ReactNode }) {
  const access = await getAccess();
  const groups: ClientNavGroup[] = visibleNav(access.is_super_admin, access.permissions, access.scoped.map((x) => x.permission));
  const supabase = await createClient();
  const { data: notes } = await supabase.rpc("my_notifications", { p_limit: 15 });
  const n = (notes ?? { unread: 0, items: [] }) as { unread: number; items: NotificationItem[] };
  // alert scan and message queue run after the page is sent (throttled)
  after(() => backgroundHousekeeping(supabase));
  return <AppShell access={access} groups={groups} notifications={n}>{children}</AppShell>;
}
