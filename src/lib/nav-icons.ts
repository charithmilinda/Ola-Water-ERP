import { Circle, LayoutDashboard, QrCode, ScrollText, Settings, ShieldCheck, Users } from "lucide-react";

/** Icons available to navigation items (add one here when a module is added). */
export const NAV_ICONS = {
  LayoutDashboard,
  QrCode,
  ScrollText,
  Users,
  ShieldCheck,
  Settings,
  Circle,
} as const;

export type NavIconName = keyof typeof NAV_ICONS;
