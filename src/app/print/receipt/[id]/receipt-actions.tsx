"use client";

import { useState, useTransition } from "react";
import { Printer } from "lucide-react";
import { recordReceiptPrint } from "./actions";

export function ReceiptActions({ invoiceId, printCount }: { invoiceId: string; printCount: number }) {
  const [reason, setReason] = useState("");
  const [msg, setMsg] = useState("");
  const [pending, start] = useTransition();
  const reprint = printCount > 0;
  const go = () =>
    start(async () => {
      const res = await recordReceiptPrint(invoiceId, reprint ? reason : null);
      if (!res.ok) return setMsg(res.message);
      setMsg("");
      setTimeout(() => window.print(), 100);
    });
  return (
    <div className="no-print mx-auto mb-4 flex w-[80mm] flex-col gap-2">
      {reprint && (
        <input value={reason} onChange={(e) => setReason(e.target.value)} placeholder="Reason for reprint (required)" className="h-10 rounded-lg border border-line px-3 text-sm" />
      )}
      <button onClick={go} disabled={pending || (reprint && !reason.trim())} className="flex h-11 items-center justify-center gap-2 rounded-lg bg-ola-600 font-medium text-white disabled:opacity-50">
        <Printer className="h-4 w-4" /> {reprint ? "Reprint receipt" : "Print receipt"}
      </button>
      {msg && <p className="text-sm text-red-700">{msg}</p>}
    </div>
  );
}
