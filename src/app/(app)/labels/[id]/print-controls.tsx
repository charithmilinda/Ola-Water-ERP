"use client";

import { useState, useTransition } from "react";
import { Printer } from "lucide-react";
import { Button, buttonVariants } from "@/components/ui/button";
import { Alert } from "@/components/ui/alert";
import { ReasonDialog } from "@/components/ui/reason-dialog";
import { recordLabelPrint, reprintAction } from "../actions";
import type { ActionResult } from "@/lib/actions";

export function PrintControls({
  batchId,
  printCount,
  parts,
  canPrint,
}: {
  batchId: string;
  printCount: number;
  parts: { part: number; from: string; to: string; count: number }[];
  canPrint: boolean;
}) {
  const [unlocked, setUnlocked] = useState(false);
  const [message, setMessage] = useState<ActionResult | null>(null);
  const [pending, start] = useTransition();

  if (!canPrint) return <p className="text-sm text-muted">You can view this batch but not print it.</p>;

  const firstPrint = () =>
    start(async () => {
      const res = await recordLabelPrint(batchId, null);
      setMessage(res);
      if (res.ok) setUnlocked(true);
    });

  const reprint = async (prev: ActionResult, form: FormData) => {
    const res = await reprintAction(prev, form);
    if (res.ok) setUnlocked(true);
    return res;
  };

  return (
    <div className="space-y-4">
      {message && !message.ok && <Alert tone="error">{message.message}</Alert>}
      {!unlocked && (
        <div className="flex flex-wrap items-center gap-3">
          {printCount === 0 ? (
            <Button onClick={firstPrint} disabled={pending}>
              <Printer className="h-4 w-4" /> {pending ? "Recording…" : "Print labels"}
            </Button>
          ) : (
            <ReasonDialog
              trigger={
                <>
                  <Printer className="h-4 w-4" /> Reprint labels
                </>
              }
              triggerVariant="primary"
              triggerSize="md"
              title="Reprint labels"
              description="These labels were printed before. Reprinting can create duplicate physical labels — destroy any spoiled copies."
              confirmLabel="Continue to print"
              action={reprint}
              hidden={{ batch_id: batchId }}
            />
          )}
          <p className="text-sm text-muted">Printing is recorded in the audit trail.</p>
        </div>
      )}
      {unlocked && (
        <div>
          <Alert tone="success" className="mb-3">
            Print recorded. Open each part below and print it on the label printer (one label per page, scale 100%).
          </Alert>
          <ul className="divide-y divide-line rounded-lg border border-line">
            {parts.map((p) => (
              <li key={p.part} className="flex flex-wrap items-center justify-between gap-3 px-4 py-3 text-sm">
                <span>
                  <span className="font-medium">Part {p.part}</span>{" "}
                  <span className="font-mono text-xs text-muted">
                    {p.from} → {p.to}
                  </span>{" "}
                  <span className="text-muted">({p.count} labels)</span>
                </span>
                <a
                  href={`/print/labels/${batchId}?part=${p.part}`}
                  target="_blank"
                  rel="noopener"
                  className={buttonVariants({ variant: "secondary", size: "sm" })}
                >
                  <Printer className="h-4 w-4" /> Open part {p.part}
                </a>
              </li>
            ))}
          </ul>
        </div>
      )}
    </div>
  );
}
