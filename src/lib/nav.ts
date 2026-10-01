import type { NavIconName } from "./nav-icons";

export type NavItem = {
  href: string;
  label: string;
  icon: NavIconName;
  /** Any one of these permissions shows the item. Empty = every signed-in user. */
  permissions: string[];
};

export type NavGroup = { label: string; items: NavItem[] };

/**
 * Only modules that are actually built appear here. Each later phase adds its
 * modules to this list (Customers, Bottles, Deliveries, Water Shops, ...).
 */
export const NAV: NavGroup[] = [
  {
    label: "Overview",
    items: [{ href: "/", label: "Home", icon: "LayoutDashboard", permissions: [] }],
  },
  {
    label: "Bottles",
    items: [{ href: "/labels", label: "Label Printing", icon: "QrCode", permissions: ["labels.print", "labels.view"] }],
  },
  {
    label: "Admin",
    items: [
      { href: "/audit", label: "Audit Trail", icon: "ScrollText", permissions: ["audit.view"] },
      { href: "/admin/users", label: "Users", icon: "Users", permissions: ["users.manage"] },
      { href: "/admin/roles", label: "Roles & Permissions", icon: "ShieldCheck", permissions: ["roles.manage"] },
      { href: "/admin/settings", label: "System Settings", icon: "Settings", permissions: ["settings.manage"] },
    ],
  },
];

export function visibleNav(isSuperAdmin: boolean, permissions: string[]): NavGroup[] {
  return NAV.map((g) => ({
    ...g,
    items: g.items.filter(
      (i) => i.permissions.length === 0 || isSuperAdmin || i.permissions.some((p) => permissions.includes(p)),
    ),
  })).filter((g) => g.items.length > 0);
}
