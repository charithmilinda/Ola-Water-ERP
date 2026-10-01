"use client";

import { useId, useRef } from "react";
import { X } from "lucide-react";
import type { ActionResult } from "@/lib/actions";
import { ActionForm } from "./action-form";
import { Button, type ButtonProps } from "./button";
import { Field, Textarea } from "./field";
import { SubmitButton } from "./submit-button";

/**
 * Confirmation dialog for sensitive actions. Collects a mandatory reason that
 * is stored in the audit trail.
 */
export function ReasonDialog({
  trigger,
  triggerVariant = "secondary",
  triggerSize = "sm",
  title,
  description,
  confirmLabel,
  confirmVariant = "primary",
  action,
  hidden,
  reasonRequired = true,
  children,
}: {
  trigger: React.ReactNode;
  triggerVariant?: ButtonProps["variant"];
  triggerSize?: ButtonProps["size"];
  title: string;
  description?: string;
  confirmLabel: string;
  confirmVariant?: ButtonProps["variant"];
  action: (prev: ActionResult, form: FormData) => Promise<ActionResult>;
  hidden?: Record<string, string>;
  reasonRequired?: boolean;
  children?: React.ReactNode;
}) {
  const ref = useRef<HTMLDialogElement>(null);
  const reasonId = useId();
  return (
    <>
      <Button type="button" variant={triggerVariant} size={triggerSize} onClick={() => ref.current?.showModal()}>
        {trigger}
      </Button>
      <dialog ref={ref} className="m-auto w-[min(32rem,calc(100vw-2rem))] rounded-xl border border-line p-0 shadow-xl">
        <div className="flex items-start justify-between border-b border-line px-5 py-4">
          <div>
            <h2 className="text-base font-semibold text-navy-900">{title}</h2>
            {description && <p className="mt-1 text-sm text-muted">{description}</p>}
          </div>
          <Button type="button" variant="ghost" size="icon" aria-label="Close" onClick={() => ref.current?.close()}>
            <X className="h-4 w-4" />
          </Button>
        </div>
        <ActionForm action={action} className="p-5" onSuccess={() => setTimeout(() => ref.current?.close(), 900)} resetOnSuccess>
          {hidden && Object.entries(hidden).map(([k, v]) => <input key={k} type="hidden" name={k} value={v} />)}
          {children}
          <Field label="Reason" htmlFor={reasonId} required={reasonRequired} hint="Recorded in the audit trail.">
            <Textarea id={reasonId} name="reason" required={reasonRequired} maxLength={500} />
          </Field>
          <div className="flex justify-end gap-2 pt-1">
            <Button type="button" variant="secondary" onClick={() => ref.current?.close()}>
              Cancel
            </Button>
            <SubmitButton variant={confirmVariant}>{confirmLabel}</SubmitButton>
          </div>
        </ActionForm>
      </dialog>
    </>
  );
}
