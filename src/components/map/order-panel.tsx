import { ActionForm } from "@/components/ui/action-form";
import { SubmitButton } from "@/components/ui/submit-button";
import { StopMap, type MapPoint } from "./stop-map";

type Stop = { id: string; name: string; detail?: string | null; lat: number | null; lng: number | null; current_seq: number | null };

/**
 * Current vs suggested visiting order, with a map, and a button that saves
 * the suggestion. Used for a run's stops and for a route's customers.
 */
export function OrderPanel({ start, current, suggested, noGps, currentKm, suggestedKm, closeLoop, canApply, action, hidden, applyLabel }: {
  start: { name: string; lat: number; lng: number } | null;
  current: Stop[]; suggested: Stop[]; noGps: Stop[];
  currentKm: number | null; suggestedKm: number | null; closeLoop: boolean; canApply: boolean;
  action: (prev: import("@/lib/actions").ActionResult, form: FormData) => Promise<import("@/lib/actions").ActionResult>;
  hidden: Record<string, string>; applyLabel: string;
}) {
  const pts = (list: Stop[]): MapPoint[] => [
    ...(start ? [{ lat: Number(start.lat), lng: Number(start.lng), label: start.name, seq: "★", tone: "start" as const }] : []),
    ...list.filter((s) => s.lat !== null).map((s, i) => ({ lat: Number(s.lat), lng: Number(s.lng), label: s.name, seq: i + 1 })),
  ];
  const saves = currentKm !== null && suggestedKm !== null ? Number(currentKm) - Number(suggestedKm) : 0;
  const same = suggested.map((s) => s.id).join() === current.filter((s) => s.lat !== null).map((s) => s.id).join();
  const order = JSON.stringify([...suggested.map((s) => s.id), ...noGps.map((s) => s.id)]);
  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center gap-x-6 gap-y-2 text-sm">
        <span>Now: <strong className="num">{currentKm ?? "—"} km</strong></span>
        <span>Suggested: <strong className="num">{suggestedKm ?? "—"} km</strong></span>
        {saves > 0.05 && <span className="font-medium text-emerald-700">Saves about {saves.toFixed(1)} km</span>}
        {same && <span className="text-muted">The current order is already the best found.</span>}
        <span className="text-xs text-muted">Estimated from GPS points{start ? `, starting at ${start.name}` : ""}{closeLoop ? " and returning" : ""}.</span>
      </div>
      <div className="grid gap-4 lg:grid-cols-2">
        <div>
          <p className="mb-1 text-xs font-semibold uppercase tracking-wide text-muted">Suggested order</p>
          <StopMap points={pts(suggested)} closeLoop={closeLoop} height={320} />
        </div>
        <div>
          <p className="mb-1 text-xs font-semibold uppercase tracking-wide text-muted">Visiting order</p>
          <ol className="max-h-80 divide-y divide-line overflow-y-auto rounded-lg ring-1 ring-line text-sm">
            {suggested.map((s, i) => (
              <li key={s.id} className="flex items-center justify-between gap-2 px-3 py-2">
                <span><span className="mr-2 inline-flex h-6 w-6 items-center justify-center rounded-full bg-ola-600 text-xs font-semibold text-white">{i + 1}</span>{s.name}
                  {s.detail && <span className="block pl-8 text-xs text-muted">{s.detail}</span>}</span>
                {s.current_seq !== null && <span className="text-xs text-muted">was {s.current_seq}</span>}
              </li>))}
            {noGps.map((s) => (
              <li key={s.id} className="flex items-center justify-between gap-2 bg-amber-50/60 px-3 py-2">
                <span><span className="mr-2 inline-flex h-6 w-6 items-center justify-center rounded-full bg-amber-500 text-xs font-semibold text-white">?</span>{s.name}
                  <span className="block pl-8 text-xs text-amber-800">No GPS on the address — kept at the end</span></span>
              </li>))}
          </ol>
        </div>
      </div>
      {canApply && !same && suggested.length > 1 && (
        <ActionForm action={action} className="flex flex-wrap items-center gap-3">
          {Object.entries(hidden).map(([k, v]) => <input key={k} type="hidden" name={k} value={v} />)}
          <input type="hidden" name="order" value={order} />
          <SubmitButton>{applyLabel}</SubmitButton>
        </ActionForm>
      )}
      {noGps.length > 0 && <p className="text-xs text-muted">Add the GPS location on those customers&apos; addresses (open the customer → Addresses) so they can be placed too.</p>}
    </div>
  );
}
