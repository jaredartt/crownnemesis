/* Crown Nemesis service worker -- push notifications only (no caching).
   A push arrives from the send-push function with {title, body, url, tag}.
   If the game is open and visible the in-game bell already shows it, so it is
   skipped; otherwise it pops up like any phone notification. */
self.addEventListener('install', () => self.skipWaiting())
self.addEventListener('activate', (e) => e.waitUntil(self.clients.claim()))

self.addEventListener('push', (event) => {
  let d = {}
  try { d = event.data ? event.data.json() : {} } catch (_) { /* plain text push */ }
  event.waitUntil((async () => {
    const wins = await self.clients.matchAll({ type: 'window', includeUncontrolled: true })
    if (wins.some((w) => w.visibilityState === 'visible')) return
    await self.registration.showNotification(d.title || 'Crown Nemesis', {
      body: d.body || '',
      icon: './icon-192.png',
      badge: './icon-192.png',
      tag: d.tag || undefined,
      data: { url: d.url || './' },
    })
  })())
})

self.addEventListener('notificationclick', (event) => {
  event.notification.close()
  const url = new URL((event.notification.data && event.notification.data.url) || './', self.registration.scope).href
  event.waitUntil((async () => {
    const wins = await self.clients.matchAll({ type: 'window', includeUncontrolled: true })
    for (const w of wins) {
      if ('focus' in w) { await w.focus(); return }
    }
    await self.clients.openWindow(url)
  })())
})
