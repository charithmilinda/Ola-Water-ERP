"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { browserClient } from "@/lib/supabase/browser";
import { kv, outbox, type OutboxItem } from "./store";
import type { RunData, RunSummary } from "./types";

type PgError = { message: string; code?: string } | null;

/** A network failure (retry later) vs. a business error from the database (needs attention). */
function isNetworkError(e: PgError | unknown): boolean {
  if (!e) return false;
  const err = e as { message?: string; code?: string };
  return !err.code && /fetch|network|Failed|Load failed|timeout/i.test(err.message ?? "");
}

export function useDriverSync() {
  const [online, setOnline] = useState(true);
  const [items, setItems] = useState<OutboxItem[]>([]);
  const [syncing, setSyncing] = useState(false);
  const busy = useRef(false);

  const refreshOutbox = useCallback(async () => setItems(await outbox.all()), []);

  const sync = useCallback(async () => {
    if (busy.current || !navigator.onLine) return;
    busy.current = true;
    setSyncing(true);
    const sb = browserClient();
    try {
      for (const item of await outbox.all()) {
        if (item.status === "error") continue;
        // 1. photo first
        if (item.photo && !item.photo.uploaded) {
          const blob = await (await fetch(item.photo.data_url)).blob();
          const { error } = await sb.storage.from("delivery-proofs").upload(item.photo.path, blob, { contentType: "image/jpeg", upsert: true });
          if (error && isNetworkError(error)) break;
          item.photo.uploaded = !error;
          if (!error) {
            const p = item.args.p as Record<string, unknown> & { confirmation?: Record<string, unknown> };
            if (p.confirmation) p.confirmation.photo_path = item.photo.path;
            else p.receipt_path = item.photo.path;
          }
          await outbox.put(item);
        }
        // 2. the transaction itself (idempotent on client_txn_id)
        const { data, error } = await sb.rpc(item.fn, item.args);
        if (error) {
          if (isNetworkError(error)) break;
          item.status = "error";
          item.error = error.message;
          item.attempts += 1;
          await outbox.put(item);
          continue;
        }
        if (item.fn === "complete_delivery" && item.delivery_id) await kv.set(`receipt:${item.delivery_id}`, data);
        await outbox.del(item.id);
      }
    } catch {
      // stay pending; try again later
    } finally {
      busy.current = false;
      setSyncing(false);
      await refreshOutbox();
    }
  }, [refreshOutbox]);

  useEffect(() => {
    setOnline(navigator.onLine);
    refreshOutbox();
    const up = () => { setOnline(true); sync(); };
    const down = () => setOnline(false);
    window.addEventListener("online", up);
    window.addEventListener("offline", down);
    const t = setInterval(() => sync(), 30000);
    sync();
    return () => { window.removeEventListener("online", up); window.removeEventListener("offline", down); clearInterval(t); };
  }, [sync, refreshOutbox]);

  const enqueue = useCallback(async (item: OutboxItem) => {
    await outbox.put(item);
    await refreshOutbox();
    sync();
  }, [sync, refreshOutbox]);

  const retry = useCallback(async (id: string) => {
    const all = await outbox.all();
    const it = all.find((x) => x.id === id);
    if (!it) return;
    it.status = "pending";
    it.error = undefined;
    await outbox.put(it);
    await refreshOutbox();
    sync();
  }, [sync, refreshOutbox]);

  return { online, items, syncing, sync, enqueue, retry };
}

/** Fetch from the server when online; otherwise use the copy saved on the phone. */
export async function loadRuns(): Promise<{ runs: RunSummary[]; offline: boolean }> {
  try {
    const { data, error } = await browserClient().rpc("driver_my_runs");
    if (error) throw error;
    await kv.set("runs", data);
    return { runs: data as RunSummary[], offline: false };
  } catch {
    return { runs: ((await kv.get<RunSummary[]>("runs")) ?? []), offline: true };
  }
}

export async function loadRun(runId: string): Promise<{ run: RunData | null; offline: boolean; error?: string }> {
  try {
    const { data, error } = await browserClient().rpc("driver_get_run", { p_run: runId });
    if (error) {
      if (!isNetworkError(error)) return { run: (await kv.get<RunData>(`run:${runId}`)) ?? null, offline: false, error: error.message };
      throw error;
    }
    const fresh = { ...(data as RunData), fetched_at: new Date().toISOString() };
    // keep local, not-yet-synced results on top of server data
    const local = await kv.get<RunData>(`run:${runId}`);
    const queued = (await outbox.all()).filter((i) => i.run_id === runId);
    const pending = new Set(queued.map((i) => i.delivery_id));
    const pendingIds = new Set(queued.map((i) => i.id));
    if (local) {
      fresh.stops = fresh.stops.map((s) => {
        const l = local.stops.find((x) => x.delivery_id === s.delivery_id);
        return l?.local && pending.has(s.delivery_id) ? { ...s, status: l.status, local: l.local } : s;
      });
      // road expenses entered on the phone but not yet on the server
      const known = new Set((fresh.driver_expenses ?? []).map((x) => x.id));
      const waiting = (local.driver_expenses ?? []).filter((x) => x.pending && pendingIds.has(x.id) && !known.has(x.id));
      fresh.driver_expenses = [...(fresh.driver_expenses ?? []), ...waiting];
    }
    await kv.set(`run:${runId}`, fresh);
    return { run: fresh, offline: false };
  } catch {
    return { run: (await kv.get<RunData>(`run:${runId}`)) ?? null, offline: true };
  }
}

export async function saveRunLocal(run: RunData) {
  await kv.set(`run:${run.run.id}`, run);
}
