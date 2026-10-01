"use client";

import { useActionState, useEffect, useRef, useState } from "react";
import type { ActionResult } from "@/lib/actions";
import { Alert } from "./alert";
import { cn } from "@/lib/cn";

type Action = (prev: ActionResult, form: FormData) => Promise<ActionResult>;

/**
 * Form bound to a server action. Shows success / error messages, and adds a
 * fresh client_txn_id (idempotency key) for every submission so that a
 * double-click or a retry never creates a duplicate record.
 */
export function ActionForm({
  action,
  children,
  className,
  resetOnSuccess = false,
  onSuccess,
}: {
  action: Action;
  children: React.ReactNode;
  className?: string;
  resetOnSuccess?: boolean;
  onSuccess?: (result: ActionResult) => void;
}) {
  const [state, formAction] = useActionState<ActionResult, FormData>(action, { ok: true, message: "" });
  const [txnId, setTxnId] = useState<string>("");
  const formRef = useRef<HTMLFormElement>(null);

  useEffect(() => setTxnId(crypto.randomUUID()), []);

  useEffect(() => {
    if (!state.message) return;
    if (state.ok) {
      setTxnId(crypto.randomUUID());
      if (resetOnSuccess) formRef.current?.reset();
      onSuccess?.(state);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [state]);

  return (
    <form ref={formRef} action={formAction} className={cn("space-y-4", className)}>
      <input type="hidden" name="client_txn_id" value={txnId} />
      {state.message && <Alert tone={state.ok ? "success" : "error"}>{state.message}</Alert>}
      {children}
    </form>
  );
}
