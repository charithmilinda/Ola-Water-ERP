import type { Metadata, Viewport } from "next";
import { requireAnywhere } from "@/lib/access";
import { isUuid } from "@/lib/actions";
import { RegisterSW } from "@/app/driver/register-sw";
import { PosApp } from "./pos-app";
import { posSignOut } from "./actions";

export const metadata: Metadata = { title: "Till", manifest: "/manifest-pos.webmanifest" };
export const viewport: Viewport = { themeColor: "#1868d6", width: "device-width", initialScale: 1, maximumScale: 1 };

export default async function PosPage({ searchParams }: { searchParams: Promise<{ location?: string }> }) {
  const access = await requireAnywhere(["pos.use", "shop_pos.use"]);
  const { location } = await searchParams;
  return (
    <>
      <RegisterSW />
      <PosApp userName={access.full_name} initialLocation={location && isUuid(location) ? location : null} signOut={posSignOut} />
    </>
  );
}
