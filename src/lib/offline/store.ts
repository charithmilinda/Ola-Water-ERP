"use client";

// Small IndexedDB wrapper shared by the offline-capable screens (driver app, tills):
// a key-value store for cached data and an outbox of transactions waiting for the server.

export type OutboxItem = {
  id: string; // client_txn_id — the server ignores a repeat of the same id
  fn: string; // database function to call
  args: Record<string, unknown>;
  label: string;
  created_at: string;
  status: "pending" | "error";
  error?: string;
  attempts: number;
  run_id?: string;
  delivery_id?: string;
  session_id?: string;
  photo?: { data_url: string; path: string; uploaded: boolean };
};

export function createOfflineStore(dbName: string) {
  function open(): Promise<IDBDatabase> {
    return new Promise((resolve, reject) => {
      const req = indexedDB.open(dbName, 1);
      req.onupgradeneeded = () => {
        const db = req.result;
        if (!db.objectStoreNames.contains("kv")) db.createObjectStore("kv");
        if (!db.objectStoreNames.contains("outbox")) db.createObjectStore("outbox", { keyPath: "id" });
      };
      req.onsuccess = () => resolve(req.result);
      req.onerror = () => reject(req.error);
    });
  }

  async function tx<T>(store: string, mode: IDBTransactionMode, fn: (s: IDBObjectStore) => IDBRequest<T>): Promise<T> {
    const db = await open();
    return new Promise((resolve, reject) => {
      const t = db.transaction(store, mode);
      const req = fn(t.objectStore(store));
      req.onsuccess = () => resolve(req.result);
      req.onerror = () => reject(req.error);
    });
  }

  return {
    kv: {
      get: <T>(key: string) => tx<T | undefined>("kv", "readonly", (s) => s.get(key) as IDBRequest<T | undefined>),
      set: (key: string, value: unknown) => tx("kv", "readwrite", (s) => s.put(value, key)),
      del: (key: string) => tx("kv", "readwrite", (s) => s.delete(key)),
    },
    outbox: {
      all: async () =>
        (await tx<OutboxItem[]>("outbox", "readonly", (s) => s.getAll() as IDBRequest<OutboxItem[]>)).sort((a, b) => a.created_at.localeCompare(b.created_at)),
      put: (item: OutboxItem) => tx("outbox", "readwrite", (s) => s.put(item)),
      del: (id: string) => tx("outbox", "readwrite", (s) => s.delete(id)),
    },
  };
}

/** A network failure (keep and retry later) vs. a refusal from the database (needs a person). */
export function isNetworkError(e: unknown): boolean {
  if (!e) return false;
  const err = e as { message?: string; code?: string };
  return !err.code && /fetch|network|Failed|Load failed|timeout/i.test(err.message ?? "");
}
