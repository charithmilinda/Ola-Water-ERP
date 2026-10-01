"use client";

import { useRef } from "react";
import { X } from "lucide-react";
import type { ActionResult } from "@/lib/actions";
import { ActionForm } from "./action-form";
import { Button, type ButtonProps } from "./button";
import { SubmitButton } from "./submit-button";
import { cn } from "@/lib/cn";

/** A dialog containing a form bound to a server action. */
export function FormDialog({
  trigger,
  triggerVariant = "secondary",
  triggerSize = "sm",
  title,
  description,
  submitLabel,
  action,
  hidden,
  children,
  wide,
  closeOnSuccess = true,
}: {
  trigger: React.ReactNode;
  triggerVariant?: ButtonProps["variant"];
  triggerSize?: ButtonProps["size"];
  title: string;
  description?: string;
  submitLabel: string;
  action: (prev: ActionResult, form: FormData) => Promise<ActionResult>;
  hidden?: Record<string, string>;
  children: React.ReactNode;
  wide?: boolean;
  closeOnSuccess?: boolean;
}) {
  const ref = useRef<HTMLDialogElement>(null);
  return (
    <>
      <Button type="button" variant={triggerVariant} size={triggerSize} onClick={() => ref.current?.showModal()}>
        {trigger}
      </Button>
      <dialog
        ref={ref}
        className={cn("m-auto max-h-[90dvh] rounded-xl border border-line p-0 shadow-xl", wide ? "w-[min(48rem,calc(100vw-2rem))]" : "w-[min(32rem,calc(100vw-2rem))]")}
      >
        <div className="sticky top-0 z-10 flex items-start justify-between border-b border-line bg-white px-5 py-4">
          <div>
            <h2 className="text-base font-semibold text-navy-900">{title}</h2>
            {description && <p className="mt-1 text-sm text-muted">{description}</p>}
          </div>
          <Button type="button" variant="ghost" size="icon" aria-label="Close" onClick={() => ref.current?.close()}>
            <X className="h-4 w-4" />
          </Button>
        </div>
        <ActionForm action={action} className="p-5" onSuccess={() => closeOnSuccess && setTimeout(() => ref.current?.close(), 700)}>
          {hidden && Object.entries(hidden).map(([k, v]) => <input key={k} type="hidden" name={k} value={v} />)}
          {children}
          <div className="flex justify-end gap-2 pt-1">
            <Button type="button" variant="secondary" onClick={() => ref.current?.close()}>
              Cancel
            </Button>
            <SubmitButton>{submitLabel}</SubmitButton>
          </div>
        </ActionForm>
      </dialog>
    </>
  );
}
