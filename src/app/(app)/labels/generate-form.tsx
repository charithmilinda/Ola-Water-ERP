"use client";

import { ActionForm } from "@/components/ui/action-form";
import { Field, Input, Select, Textarea } from "@/components/ui/field";
import { SubmitButton } from "@/components/ui/submit-button";
import { generateLabelBatch } from "./actions";

export function GenerateLabelsForm({ series }: { series: { code: string; name: string; next_value: number; padding: number }[] }) {
  return (
    <ActionForm action={generateLabelBatch}>
      <Field label="Label series" htmlFor="series" required>
        <Select id="series" name="series" required defaultValue={series[0]?.code}>
          {series.map((s) => (
            <option key={s.code} value={s.code}>
              {s.name} — next {s.code}-{String(s.next_value).padStart(s.padding, "0")}
            </option>
          ))}
        </Select>
      </Field>
      <div className="grid gap-4 sm:grid-cols-3">
        <Field label="Quantity" htmlFor="quantity" required hint="1 – 5,000">
          <Input id="quantity" name="quantity" type="number" inputMode="numeric" min={1} max={5000} defaultValue={100} required />
        </Field>
        <Field label="Code type" htmlFor="symbology" required>
          <Select id="symbology" name="symbology" defaultValue="qrcode">
            <option value="qrcode">QR code</option>
            <option value="datamatrix">Data Matrix</option>
            <option value="code128">Code 128 (1D)</option>
          </Select>
        </Field>
        <Field label="Label size (mm)" htmlFor="size" required>
          <Select id="size" name="size" defaultValue="50x25">
            <option value="50x25">50 × 25</option>
            <option value="40x30">40 × 30</option>
            <option value="30x20">30 × 20</option>
          </Select>
        </Field>
      </div>
      <Field label="Notes" htmlFor="notes" hint="Optional, e.g. which roll or which warehouse">
        <Textarea id="notes" name="notes" maxLength={300} />
      </Field>
      <p className="text-xs text-muted">
        QR and Data Matrix read best on phone cameras and curved, wet bottles. Use Code 128 only for flat surfaces scanned with a
        handheld scanner.
      </p>
      <SubmitButton pendingText="Generating…">Generate labels</SubmitButton>
    </ActionForm>
  );
}
