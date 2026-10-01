// OLA offline support (driver app and shop till).
// - Static assets (/_next/static, icons): cache-first (they are versioned).
// - The /driver and /pos pages: network-first, falling back to the last saved copy.
// - Everything else (API calls to Supabase, other pages): network only.
const CACHE = "ola-offline-v2";
const PAGES = ["/driver", "/pos"];

self.addEventListener("install", (e) => {
  self.skipWaiting();
  e.waitUntil(caches.open(CACHE).then((c) => c.addAll(PAGES).catch(() => {})));
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

  if (url.pathname.startsWith("/_next/static/") || url.pathname === "/icon.svg" || url.pathname === "/manifest.webmanifest" || url.pathname === "/manifest-pos.webmanifest") {
    e.respondWith(
      caches.match(req).then((hit) => hit || fetch(req).then((res) => {
        const copy = res.clone();
        caches.open(CACHE).then((c) => c.put(req, copy));
        return res;
      })),
    );
    return;
  }

  if (PAGES.includes(url.pathname) && req.mode === "navigate") {
    const key = url.pathname;
    e.respondWith(
      fetch(req).then((res) => {
        if (res.ok && !res.redirected) {
          const copy = res.clone();
          caches.open(CACHE).then((c) => c.put(key, copy));
        }
        return res;
      }).catch(() => caches.match(key).then((hit) => hit || new Response("Offline — open this page once while online.", { status: 503 }))),
    );
  }
});
