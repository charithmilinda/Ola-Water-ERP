// OLA Driver offline support.
// - Static assets (/_next/static, icons): cache-first (they are versioned).
// - The /driver page: network-first, falling back to the last saved copy.
// - Everything else (API calls to Supabase, other pages): network only.
const CACHE = "ola-driver-v1";

self.addEventListener("install", (e) => {
  self.skipWaiting();
  e.waitUntil(caches.open(CACHE).then((c) => c.addAll(["/driver"]).catch(() => {})));
});

self.addEventListener("activate", (e) => {
  e.waitUntil(
    caches.keys().then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k)))).then(() => self.clients.claim()),
  );
});

self.addEventListener("fetch", (e) => {
  const req = e.request;
  if (req.method !== "GET") return;
  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return;

  if (url.pathname.startsWith("/_next/static/") || url.pathname === "/icon.svg" || url.pathname === "/manifest.webmanifest") {
    e.respondWith(
      caches.match(req).then((hit) => hit || fetch(req).then((res) => {
        const copy = res.clone();
        caches.open(CACHE).then((c) => c.put(req, copy));
        return res;
      })),
    );
    return;
  }

  if (url.pathname === "/driver" && req.mode === "navigate") {
    e.respondWith(
      fetch(req).then((res) => {
        if (res.ok && !res.redirected) {
          const copy = res.clone();
          caches.open(CACHE).then((c) => c.put("/driver", copy));
        }
        return res;
      }).catch(() => caches.match("/driver").then((hit) => hit || new Response("Offline — open the driver app once while online.", { status: 503 }))),
    );
  }
});
