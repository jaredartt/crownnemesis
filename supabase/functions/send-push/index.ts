// send-push: delivers one Web Push message to every saved device of the given users.
// Called ONLY by the database (cn_push_send, via pg_net) with the shared secret in
// x-hook-secret; the secret, the VAPID keys and the contact address live in the
// locked-down table public.push_config -- never in this file or the repo.
import { createClient } from 'npm:@supabase/supabase-js@2'
import webpush from 'npm:web-push@3.6.7'

Deno.serve(async (req) => {
  const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!)
  const { data: cfg } = await sb.from('push_config').select('*').eq('id', 1).maybeSingle()
  if (!cfg || req.headers.get('x-hook-secret') !== cfg.hook_secret) {
    return new Response('forbidden', { status: 403 })
  }
  const b = await req.json().catch(() => null) as
    { user_ids?: string[]; title?: string; body?: string; url?: string; tag?: string } | null
  if (!b?.user_ids?.length) return new Response(JSON.stringify({ sent: 0 }), { status: 200 })

  webpush.setVapidDetails(cfg.subject, cfg.vapid_public, cfg.vapid_private)
  const { data: subs } = await sb.from('push_subscriptions')
    .select('endpoint,p256dh,auth').in('user_id', b.user_ids)
  const payload = JSON.stringify({ title: b.title, body: b.body, url: b.url ?? './', tag: b.tag })

  const dead: string[] = []
  let sent = 0
  await Promise.all((subs ?? []).map(async (s) => {
    try {
      await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, payload, { TTL: 3600 })
      sent++
    } catch (e) {
      const code = (e as { statusCode?: number }).statusCode
      if (code === 404 || code === 410) dead.push(s.endpoint) // the device uninstalled / revoked
    }
  }))
  if (dead.length) await sb.from('push_subscriptions').delete().in('endpoint', dead)
  return new Response(JSON.stringify({ sent, dropped: dead.length }), { status: 200 })
})
