import {
  Boxes,
  Circle,
  ClipboardList,
  Droplets,
  LayoutDashboard,
  Package,
  QrCode,
  Repeat,
  Route,
  ScrollText,
  Settings,
  ShieldCheck,
  Truck,
  TriangleAlert,
  Users,
  Contact,
  Wallet,
  ArrowLeftRight,
} from "lucide-react";

/** Icons available to navigation items (add one here when a module is added). */
export const NAV_ICONS = {
  LayoutDashboard,
  QrCode,
  ScrollText,
  Users,
  ShieldCheck,
  Settings,
  Circle,
  Contact,
  ClipboardList,
  Repeat,
  Wallet,
  Droplets,
  ArrowLeftRight,
  Truck,
  TriangleAlert,
  Route,
  Boxes,
  Package,
} as const;

export type NavIconName = keyof typeof NAV_ICONS;
