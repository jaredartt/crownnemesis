import { supabase } from './supabase'

/* Phone / desktop notifications (Web Push).
   The game's own bell is unchanged and always works. This is the extra: a
   notification that pops up on the device when the game is not open. A device
   is "on" when it has a push subscription saved for the account; the per-type
   switches live on the account (profiles.push_prefs) and apply to every device. */

/** Public half of the VAPID key pair; the private half lives only on the server. */
const VAPID_PUBLIC_KEY = 'BCgeK2qyfdyBt6nLV64CPNMce18ePw4i6sunf0oobPWsHfr-IJrSlaiPGYqZQ6hWDSMzg5F_DZdxH4Hp0h5A4oI'

export const PUSH_TYPES = ['tournament', 'friend_request', 'invite_1v1', 'invite_royale', 'country_top'] as const
export type PushType = typeof PUSH_TYPES[number]
export type PushPrefs = Partial<Record<PushType, boolean>>

export function pushSupported(): boolean {
  return typeof window !== 'undefined' && 'serviceWorker' in navigator
    && 'PushManager' in window && 'Notification' in window
}

/** iPhones only allow web push for a game that was added to the Home Screen. */
export function needsHomeScreen(): boolean {
  const ua = navigator.userAgent
  const ios = /iPad|iPhone|iPod/.test(ua) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1)
  const standalone = window.matchMedia?.('(display-mode: standalone)').matches
    || (navigator as unknown as { standalone?: boolean }).standalone === true
  return ios && !standalone
}

function keyBytes(b64url: string): Uint8Array<ArrayBuffer> {
  const pad = '='.repeat((4 - (b64url.length % 4)) % 4)
  const raw = atob((b64url + pad).replace(/-/g, '+').replace(/_/g, '/'))
  const out = new Uint8Array(new ArrayBuffer(raw.length))
  for (let i = 0; i < raw.length; i++) out[i] = raw.charCodeAt(i)
  return out
}

async function registration() {
  const url = `${import.meta.env.BASE_URL}sw.js`
  return navigator.serviceWorker.register(url, { scope: import.meta.env.BASE_URL })
}

export async function currentSubscription(): Promise<PushSubscription | null> {
  if (!pushSupported()) return null
  try {
    const reg = await navigator.serviceWorker.getRegistration(import.meta.env.BASE_URL)
    return (await reg?.pushManager.getSubscription()) ?? null
  } catch { return null }
}

export type EnableResult = 'ok' | 'denied' | 'unsupported' | 'error'

/** Asks the browser for permission, subscribes, and saves the subscription. */
export async function enablePush(): Promise<EnableResult> {
  if (!pushSupported()) return 'unsupported'
  try {
    const perm = Notification.permission === 'granted' ? 'granted' : await Notification.requestPermission()
    if (perm !== 'granted') return 'denied'
    const reg = await registration()
    await navigator.serviceWorker.ready
    const sub = (await reg.pushManager.getSubscription())
      ?? (await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: keyBytes(VAPID_PUBLIC_KEY) }))
    const j = sub.toJSON()
    const { error } = await supabase.rpc('cn_push_subscribe', {
      p_endpoint: sub.endpoint, p_p256dh: j.keys?.p256dh ?? '', p_auth: j.keys?.auth ?? '',
      p_ua: navigator.userAgent.slice(0, 200),
    })
    if (error) throw error
    return 'ok'
  } catch { return 'error' }
}

export async function disablePush(): Promise<void> {
  const sub = await currentSubscription()
  if (!sub) return
  try { await supabase.rpc('cn_push_unsubscribe', { p_endpoint: sub.endpoint }) } catch { /* the endpoint is dropped below regardless */ }
  try { await sub.unsubscribe() } catch { /* already gone */ }
}

export async function fetchPushPrefs(userId: string): Promise<PushPrefs> {
  const { data } = await supabase.from('profiles').select('push_prefs').eq('id', userId).maybeSingle()
  return ((data as { push_prefs?: PushPrefs } | null)?.push_prefs) ?? {}
}

export async function savePushPrefs(prefs: PushPrefs): Promise<void> {
  const { error } = await supabase.rpc('cn_set_push_prefs', { p_prefs: prefs })
  if (error) throw error
}
