"use client";

import { useEffect } from "react";

/** Registers the service worker that keeps the driver app usable offline. */
export function RegisterSW() {
  useEffect(() => {
    if ("serviceWorker" in navigator) navigator.serviceWorker.register("/sw.js", { scope: "/" }).catch(() => {});
  }, []);
  return null;
}
