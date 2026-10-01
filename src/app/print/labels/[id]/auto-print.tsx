"use client";

import { useEffect } from "react";

export function AutoPrint() {
  useEffect(() => {
    const t = setTimeout(() => window.print(), 400);
    return () => clearTimeout(t);
  }, []);
  return (
    <button onClick={() => window.print()} className="rounded-md bg-white px-3 py-1.5 text-sm font-medium text-navy-900">
      Print again
    </button>
  );
}
