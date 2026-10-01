import type { Metadata, Viewport } from "next";
import { requirePermission } from "@/lib/access";
import { DriverApp } from "./driver-app";
import { RegisterSW } from "./register-sw";
import { driverSignOut } from "./actions";

export const metadata: Metadata = { title: "Driver", manifest: "/manifest.webmanifest" };
export const viewport: Viewport = { themeColor: "#1868d6", width: "device-width", initialScale: 1, maximumScale: 1 };

export default async function DriverPage() {
  const access = await requirePermission(["driver.app", "deliveries.manage"]);
  return (
    <>
      <RegisterSW />
      <DriverApp userName={access.full_name} signOut={driverSignOut} />
    </>
  );
}
