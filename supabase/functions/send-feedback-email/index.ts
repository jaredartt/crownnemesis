// Jared: "can we also link the feedback/bug report thing to emails? So
// that whenever I receive a message like that, I receive an email to
// jaredartt@gmail.com. Also if I respond to them through the game (inside
// the admin panel), my responses are sent to them as emails to the email
// that they put in a field in those messages."
//
// Called from two places, right after the matching RPC succeeds -- never
// from a DB trigger, so a failed send never blocks or loses the actual
// feedback row (see 0172_feedback_email_and_reply.sql's own header):
//   - FeedbackModal.tsx, right after submit_feedback: { type: "new_feedback" }
//   - AdminStats.tsx, right after admin_reply_feedback: { type: "admin_reply" }
//
// Sends through Resend (resend.com) -- RESEND_API_KEY is a Supabase Edge
// Function secret, set by Jared himself in the dashboard, never handled by
// this code or committed anywhere. Until that secret exists this function
// answers 501 rather than erroring at the caller in a confusing way; both
// call sites treat that as "couldn't send the email" without losing the
// already-saved feedback/reply.
//
// verify_jwt is ON for this function (any signed-in player may trigger
// "new_feedback" -- that's just them submitting their own report), but
// "admin_reply" is independently re-checked against Postgres here via
// cn_is_super_admin(), using the CALLER's own JWT -- never trusted from
// the request body. Skipping that check would turn this into an open
// relay: anything in the request would go out under Jared's own Resend
// account to whatever address the caller named.
import 'jsr:@supabase/functions-js/edge-runtime.d.ts'
import { createClient } from 'jsr:@supabase/supabase-js@2'

const RESEND_API_KEY = Deno.env.get('RESEND_API_KEY')
// Resend's own sandbox sender -- works with no domain verification, but
// (per Resend's own test-mode limits) may only deliver to the address the
// Resend account itself was signed up with until a real sending domain is
// verified. Jared can override this once he verifies crownnemesis's own
// domain, by setting RESEND_FROM as a second Edge Function secret.
const FROM = Deno.env.get('RESEND_FROM') ?? 'Crown Nemesis <onboarding@resend.dev>'
const ADMIN_EMAIL = 'jaredartt@gmail.com'

function escapeHtml(s: string): string {
  return s
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&#39;')
}

function paragraph(s: string): string {
  return `<p style="white-space:pre-wrap;margin:0 0 12px">${escapeHtml(s)}</p>`
}

Deno.serve(async (req: Request) => {
  if (req.method !== 'POST') {
    return new Response(JSON.stringify({ error: 'method not allowed' }), { status: 405 })
  }
  if (!RESEND_API_KEY) {
    return new Response(
      JSON.stringify({ error: 'email sending is not configured yet (RESEND_API_KEY unset)' }),
      { status: 501, headers: { 'Content-Type': 'application/json' } },
    )
  }

  let body: Record<string, unknown>
  try {
    body = await req.json()
  } catch {
    return new Response(JSON.stringify({ error: 'bad json' }), { status: 400 })
  }

  // The platform injects these for every Edge Function automatically --
  // not RESEND_API_KEY/RESEND_FROM above, which are Jared's own secrets.
  const supabase = createClient(
    Deno.env.get('SUPABASE_URL') ?? '',
    Deno.env.get('SUPABASE_ANON_KEY') ?? '',
    { global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } } },
  )
  const { data: userData, error: userErr } = await supabase.auth.getUser()
  if (userErr || !userData?.user) {
    return new Response(JSON.stringify({ error: 'not signed in' }), { status: 401 })
  }

  const kindLabel = body.kind === 'bug' ? 'bug report' : 'feedback'
  let to: string
  let subject: string
  let html: string

  if (body.type === 'new_feedback') {
    const username = typeof body.username === 'string' && body.username ? body.username : 'a player'
    to = ADMIN_EMAIL
    subject = `New ${kindLabel} -- ${username}`
    html = [
      `<p style="margin:0 0 4px"><strong>${escapeHtml(username)}</strong> sent a new ${escapeHtml(kindLabel)}.</p>`,
      `<p style="margin:0 0 16px;color:#666;font-size:13px">Reply from: ${escapeHtml(String(body.submitterEmail ?? 'no email given'))}</p>`,
      paragraph(String(body.message ?? '')),
    ].join('\n')
  } else if (body.type === 'admin_reply') {
    // Re-checked against Postgres with the CALLER's own JWT -- see this
    // file's own header for why the request body is never trusted alone.
    const { data: isAdmin, error: adminErr } = await supabase.rpc('cn_is_super_admin')
    if (adminErr || !isAdmin) {
      return new Response(JSON.stringify({ error: 'admin only' }), { status: 403 })
    }
    if (typeof body.toEmail !== 'string' || !body.toEmail) {
      return new Response(JSON.stringify({ error: 'missing recipient' }), { status: 400 })
    }
    to = body.toEmail
    subject = `A reply to your ${kindLabel} -- Crown Nemesis`
    html = [
      paragraph(String(body.reply ?? '')),
      '<hr style="border:none;border-top:1px solid #e2e2ea;margin:16px 0">',
      '<p style="margin:0 0 4px;color:#888;font-size:12px">What you originally sent:</p>',
      `<p style="margin:0;color:#888;font-size:12px;white-space:pre-wrap">${escapeHtml(String(body.message ?? ''))}</p>`,
    ].join('\n')
  } else {
    return new Response(JSON.stringify({ error: 'unknown type' }), { status: 400 })
  }

  const sent = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: { Authorization: `Bearer ${RESEND_API_KEY}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ from: FROM, to: [to], subject, html }),
  })

  if (!sent.ok) {
    const detail = await sent.text()
    return new Response(JSON.stringify({ error: `resend: ${detail}` }), { status: 502 })
  }

  return new Response(JSON.stringify({ ok: true }), { headers: { 'Content-Type': 'application/json' } })
})
