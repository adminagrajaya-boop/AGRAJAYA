const CACHE_NAME = 'agra-jaya-pos-shell-v1';
const STATIC_SHELL_ASSETS = [
    './',
    './index.html',
    './manifest.json',
    './icons/icon-192.png',
    './icons/icon-512.png',
    './icons/icon-192-maskable.png',
    './icons/icon-512-maskable.png'
];

// 1. INSTALL EVENT — Cache static application shell assets
self.addEventListener('install', (event) => {
    event.waitUntil(
        caches.open(CACHE_NAME).then((cache) => {
            return cache.addAll(STATIC_SHELL_ASSETS).catch((err) => {
                console.warn('[SW] Non-critical error caching static shell assets:', err);
            });
        }).then(() => self.skipWaiting())
    );
});

// 2. ACTIVATE EVENT — Clean up outdated caches immediately
self.addEventListener('activate', (event) => {
    event.waitUntil(
        caches.keys().then((cacheNames) => {
            return Promise.all(
                cacheNames.map((cache) => {
                    if (cache !== CACHE_NAME) {
                        return caches.delete(cache);
                    }
                })
            );
        }).then(() => self.clients.claim())
    );
});

// 3. FETCH EVENT — Safe Network-First & Bypass Rules for Supabase
self.addEventListener('fetch', (event) => {
    const req = event.request;
    const url = new URL(req.url);

    // CRITICAL SECURITY RULE: Bypass Service Worker completely for Supabase API/Auth/Realtime
    if (url.hostname.includes('supabase.co') || 
        url.pathname.includes('/rest/v1') || 
        url.pathname.includes('/auth/v1') || 
        url.pathname.includes('/realtime/v1') ||
        req.method !== 'GET') {
        return; // Let browser handle network request natively
    }

    // Navigation / HTML Documents -> Network-First (ensures freshest code)
    if (req.mode === 'navigate' || req.headers.get('accept')?.includes('text/html')) {
        event.respondWith(
            fetch(req)
                .then((networkResponse) => {
                    if (networkResponse && networkResponse.status === 200) {
                        const responseClone = networkResponse.clone();
                        caches.open(CACHE_NAME).then((cache) => cache.put(req, responseClone));
                    }
                    return networkResponse;
                })
                .catch(() => {
                    return caches.match(req).then((cachedResponse) => {
                        return cachedResponse || caches.match('./index.html');
                    });
                })
        );
        return;
    }

    // Static Assets (Images, Stylesheets, Scripts, Fonts) -> Stale-While-Revalidate
    event.respondWith(
        caches.match(req).then((cachedResponse) => {
            const fetchPromise = fetch(req).then((networkResponse) => {
                if (networkResponse && networkResponse.status === 200 && networkResponse.type === 'basic') {
                    const responseClone = networkResponse.clone();
                    caches.open(CACHE_NAME).then((cache) => cache.put(req, responseClone));
                }
                return networkResponse;
            }).catch(() => null);

            return cachedResponse || fetchPromise;
        })
    );
});
