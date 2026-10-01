import type { NavIconName } from "./nav-icons";

export type NavItem = {
  href: string;
  label: string;
  icon: NavIconName;
  /** Any one of these permissions shows the item. Empty = every signed-in user. */
  permissions: string[];
  /** Also shown to staff who hold the permission only at their own location. */
  anywhere?: boolean;
};

export type NavGroup = { label: string; items: NavItem[] };

/**
 * Only modules that are actually built appear here. Each later phase adds its
 * modules to this list (Customers, Bottles, Deliveries, Water Shops, ...).
 */
export const NAV: NavGroup[] = [
  {
    label: "Overview",
    items: [{ href: "/", label: "Dashboard", icon: "LayoutDashboard", permissions: [] }],
  },
  {
    label: "Sales",
    items: [
      { href: "/customers", label: "Customers", icon: "Contact", permissions: ["customers.view"] },
      { href: "/orders", label: "Orders", icon: "ClipboardList", permissions: ["orders.view"] },
      { href: "/recurring", label: "Recurring Orders", icon: "Repeat", permissions: ["orders.view"] },
      { href: "/payments", label: "Payments", icon: "Wallet", permissions: ["payments.view"] },
    ],
  },
  {
    label: "Delivery",
    items: [
      { href: "/dispatch", label: "Dispatch & Runs", icon: "Truck", permissions: ["deliveries.view", "deliveries.manage"] },
      { href: "/exceptions", label: "Exceptions", icon: "TriangleAlert", permissions: ["deliveries.reconcile", "bottles.view", "shops.settle", "inventory.adjust"] },
      { href: "/routes", label: "Routes & Vehicles", icon: "Route", permissions: ["routes.manage", "fleet.manage"] },
      { href: "/driver", label: "Driver App", icon: "Truck", permissions: ["driver.app"] },
    ],
  },
  {
    label: "Water Shops",
    items: [
      { href: "/shops", label: "Shops", icon: "Store", permissions: ["shops.view", "shop_pos.use"], anywhere: true },
      { href: "/shops/requests", label: "Stock Requests", icon: "PackageCheck", permissions: ["shops.stock_approve", "inventory.manage"] },
      { href: "/pos", label: "Till / POS", icon: "Calculator", permissions: ["pos.use", "shop_pos.use"], anywhere: true },
    ],
  },
  {
    label: "Bottles",
    items: [
      { href: "/bottles", label: "Bottles", icon: "Droplets", permissions: ["bottles.view"] },
      { href: "/bottles/external", label: "External Bottles", icon: "ArrowLeftRight", permissions: ["bottles.view"] },
      { href: "/labels", label: "Label Printing", icon: "QrCode", permissions: ["labels.print", "labels.view"] },
    ],
  },
  {
    label: "Operations",
    items: [
      { href: "/inventory", label: "Inventory", icon: "Boxes", permissions: ["inventory.view"] },
      { href: "/products", label: "Products & Prices", icon: "Package", permissions: ["products.view"] },
    ],
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

export function visibleNav(isSuperAdmin: boolean, permissions: string[], scopedPermissions: string[] = []): NavGroup[] {
  return NAV.map((g) => ({
    ...g,
    items: g.items.filter(
      (i) =>
        i.permissions.length === 0 ||
        isSuperAdmin ||
        i.permissions.some((p) => permissions.includes(p)) ||
        (i.anywhere && i.permissions.some((p) => scopedPermissions.includes(p))),
    ),
  })).filter((g) => g.items.length > 0);
}
