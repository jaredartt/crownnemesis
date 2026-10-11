/**
 * "Sign in with Google" through Google's own button (Google Identity
 * Services) instead of the redirect through Supabase's OAuth screen.
 *
 * Why: the redirect flow's account chooser says "to continue to
 * dnhvfajvfhmqpbwfvyfq.supabase.co" -- the project's address, random characters
 * to a player. The Identity Services button names the site the player is on
 * instead. The token it hands back is exchanged with Supabase
 * (`signInWithIdToken`), so the account, profile trigger and session are exactly
 * the same as before.
 *
 * Needs, once, in Google Cloud: this site's origin (https://jaredartt.github.io)
 * under the OAuth client's Authorized JavaScript origins. Until that is done the
 * button errors on click, so `Auth` keeps the redirect button as a fallback when
 * the script cannot load, and `renderGoogleButton` reports failures to its caller.
 */
export const GOOGLE_CLIENT_ID = '686722194985-s8uic1jimnsjv8mk7tf79a1vh9u24slk.apps.googleusercontent.com'

interface GsiId {
  initialize: (o: Record<string, unknown>) => void
  renderButton: (el: HTMLElement, o: Record<string, unknown>) => void
}
declare global {
  interface Window { google?: { accounts?: { id?: GsiId } } }
}

let loading: Promise<GsiId> | null = null
export function loadGsi(): Promise<GsiId> {
  if (window.google?.accounts?.id) return Promise.resolve(window.google.accounts.id)
  if (loading) return loading
  loading = new Promise<GsiId>((resolve, reject) => {
    const s = document.createElement('script')
    s.src = 'https://accounts.google.com/gsi/client'
    s.async = true
    s.onload = () => {
      const id = window.google?.accounts?.id
      if (id) resolve(id); else reject(new Error('gsi missing'))
    }
    s.onerror = () => { loading = null; reject(new Error('gsi blocked')) }
    document.head.appendChild(s)
  })
  return loading
}

async function sha256Hex(s: string): Promise<string> {
  const buf = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(s))
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, '0')).join('')
}

/** Draws Google's button into `el`. `onToken(idToken, rawNonce)` gets the signed
 *  token; the nonce Google saw is the SHA-256 of `rawNonce`, which Supabase
 *  re-hashes to check. Rejects if the script or crypto is unavailable. */
export async function renderGoogleButton(
  el: HTMLElement,
  opts: { width: number; locale: string; dark: boolean; text: 'signin_with' | 'signup_with' | 'continue_with' },
  onToken: (idToken: string, rawNonce: string) => void,
): Promise<void> {
  const gsi = await loadGsi()
  const raw = crypto.getRandomValues(new Uint8Array(16)).reduce((a, b) => a + b.toString(16).padStart(2, '0'), '')
  const hashed = await sha256Hex(raw)
  gsi.initialize({
    client_id: GOOGLE_CLIENT_ID,
    nonce: hashed,
    use_fedcm_for_button: true,
    callback: (r: { credential?: string }) => { if (r.credential) onToken(r.credential, raw) },
  })
  el.innerHTML = ''
  gsi.renderButton(el, {
    type: 'standard', theme: opts.dark ? 'filled_black' : 'outline', size: 'large',
    text: opts.text, shape: 'rectangular', logo_alignment: 'left',
    width: Math.max(200, Math.min(400, Math.round(opts.width))), locale: opts.locale,
  })
}
