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
    items: [
      { href: "/", label: "Dashboard", icon: "LayoutDashboard", permissions: [] },
      { href: "/reports", label: "Reports", icon: "BarChart3", permissions: ["reports.view", "accounting.view", "sales_reps.manage", "customers.view", "inventory.view",
        "bottles.view", "deliveries.view", "deliveries.manage", "production.view", "qc.view", "complaints.view", "complaints.manage"] },
    ],
  },
  {
    label: "Control",
    items: [
      { href: "/approvals", label: "Approvals", icon: "ClipboardCheck", permissions: [] },
      { href: "/complaints", label: "Complaints", icon: "MessageSquareWarning", permissions: ["complaints.view", "complaints.manage", "qc.manage"] },
      { href: "/documents", label: "Documents", icon: "FileText", permissions: ["documents.view", "hr.view", "fleet.manage", "qc.view", "procurement.view", "payments.view"] },
    ],
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
    label: "Sales Team & CRM",
    items: [
      { href: "/sales/my", label: "My Day", icon: "MapPinned", permissions: ["payments.collect"] },
      { href: "/crm", label: "Leads & CRM", icon: "Target", permissions: ["crm.manage", "sales_reps.manage"] },
      { href: "/sales", label: "Sales Team", icon: "Briefcase", permissions: ["sales_reps.manage"] },
      { href: "/sales/commissions", label: "Commissions", icon: "Percent", permissions: ["sales_reps.manage", "payroll.approve", "expenses.approve"] },
      { href: "/distributors", label: "Distributors", icon: "Network", permissions: ["distributors.manage"] },
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
    label: "Production",
    items: [
      { href: "/production", label: "Production", icon: "Factory", permissions: ["production.view"] },
      { href: "/quality", label: "Quality Control", icon: "FlaskConical", permissions: ["qc.view"] },
      { href: "/materials", label: "Materials", icon: "Layers", permissions: ["products.view", "production.view", "procurement.view"] },
    ],
  },
  {
    label: "Purchasing",
    items: [
      { href: "/purchasing", label: "Purchasing", icon: "ShoppingCart", permissions: ["procurement.view", "inventory.manage"] },
      { href: "/suppliers", label: "Suppliers", icon: "Building2", permissions: ["procurement.view", "suppliers.manage", "payments.view"] },
    ],
  },
  {
    label: "Finance",
    items: [
      { href: "/accounting", label: "Accounting & Reports", icon: "Landmark", permissions: ["accounting.view", "payments.manage"] },
      { href: "/accounting/banking", label: "Banking & Cheques", icon: "Banknote", permissions: ["payments.manage", "accounting.view"] },
      { href: "/accounting/journals", label: "Journals", icon: "BookOpen", permissions: ["accounting.view", "accounting.manual_journal"] },
      { href: "/expenses", label: "Expenses", icon: "Receipt", permissions: ["expenses.view", "expenses.manage"] },
    ],
  },
  {
    label: "People",
    items: [
      { href: "/hr", label: "Employees", icon: "IdCard", permissions: ["hr.view", "payroll.run", "payroll.approve"] },
      { href: "/hr/attendance", label: "Attendance & Leave", icon: "CalendarCheck", permissions: ["hr.view"] },
      { href: "/payroll", label: "Payroll", icon: "HandCoins", permissions: ["payroll.run", "payroll.approve"] },
    ],
  },
  {
    label: "Fleet & Assets",
    items: [
      { href: "/fleet", label: "Fleet", icon: "Car", permissions: ["fleet.manage", "deliveries.manage"] },
      { href: "/assets", label: "Fixed Assets", icon: "Cog", permissions: ["assets.manage", "accounting.view"] },
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
      { href: "/messages", label: "Messages & Alerts", icon: "MessageCircle", permissions: ["settings.manage"] },
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
