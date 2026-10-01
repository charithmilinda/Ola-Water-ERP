"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { browserClient } from "@/lib/supabase/browser";
import { isNetworkError, type OutboxItem, type createOfflineStore } from "./store";

type Store = ReturnType<typeof createOfflineStore>;

/**
 * Replays queued transactions in order through the same database functions used
 * online. Each carries its client_txn_id, so a retry never creates a duplicate.
 * Network failures stay queued; refusals are kept and shown — never dropped.
 */
export function useOutbox(store: Store, onSynced?: (item: OutboxItem, result: unknown) => Promise<void> | void) {
  const [online, setOnline] = useState(true);
  const [items, setItems] = useState<OutboxItem[]>([]);
  const [syncing, setSyncing] = useState(false);
  const busy = useRef(false);
  const synced = useRef(onSynced);
  synced.current = onSynced;

  const refresh = useCallback(async () => setItems(await store.outbox.all()), [store]);

  const sync = useCallback(async () => {
    if (busy.current || !navigator.onLine) return;
    busy.current = true;
    setSyncing(true);
    try {
      for (const item of await store.outbox.all()) {
        if (item.status === "error") continue;
        const { data, error } = await browserClient().rpc(item.fn, item.args);
        if (error) {
          if (isNetworkError(error)) break;
          await store.outbox.put({ ...item, status: "error", error: error.message, attempts: item.attempts + 1 });
          continue;
        }
        await synced.current?.(item, data);
        await store.outbox.del(item.id);
      }
    } catch {
      // stays queued
    } finally {
      busy.current = false;
      setSyncing(false);
      await refresh();
    }
  }, [store, refresh]);

  useEffect(() => {
    setOnline(navigator.onLine);
    refresh();
    const up = () => { setOnline(true); sync(); };
    const down = () => setOnline(false);
    window.addEventListener("online", up);
    window.addEventListener("offline", down);
    const t = setInterval(sync, 20000);
    sync();
    return () => { window.removeEventListener("online", up); window.removeEventListener("offline", down); clearInterval(t); };
  }, [sync, refresh]);

  const enqueue = useCallback(async (item: OutboxItem) => {
    await store.outbox.put(item);
    await refresh();
    sync();
  }, [store, refresh, sync]);

  const retry = useCallback(async (id: string) => {
    const it = (await store.outbox.all()).find((x) => x.id === id);
    if (!it) return;
    await store.outbox.put({ ...it, status: "pending", error: undefined });
    await refresh();
    sync();
  }, [store, refresh, sync]);

  return { online, items, syncing, sync, enqueue, retry };
}
