import { useEffect, useRef, useState } from 'react'
import { sendRoyaleMessage } from '../lib/api'
import type { Profile, RoyaleMessage } from '../lib/types'
import { useT } from '../lib/i18n'
import { nameColorStyle } from '../lib/nameColors'

interface Props {
  matchId: string
  profile: Profile
  messages: RoyaleMessage[]
  open: boolean
}

/** Royale's own chat rail -- the same shape as Chat.tsx, pointed at
 *  royale_messages/send_royale_message instead of match_messages. Kept
 *  separate rather than generalising Chat.tsx: that component still
 *  hardcodes the 1v1 table directly, and nothing about 1v1 chat should
 *  risk moving to ship this. */
export function RoyaleChat({ matchId, profile, messages, open }: Props) {
  const t = useT()
  const [body, setBody] = useState('')
  const [sending, setSending] = useState(false)
  const endRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    endRef.current?.scrollIntoView({ behavior: 'smooth', block: 'end' })
  }, [messages.length])

  async function send(e: React.FormEvent) {
    e.preventDefault()
    const text = body.trim()
    if (!text || sending) return
    setSending(true)
    setBody('')
    try {
      await sendRoyaleMessage(matchId, text.slice(0, 500))
    } catch {
      setBody(text)
    }
    setSending(false)
  }

  return (
    <aside className={`side side-left${open ? ' is-open' : ''}`}>
      <h2 className="side-title">{t('chat.title')}</h2>
      <div className="side-body">
        {messages.length === 0 && <p className="muted tiny">{t('chat.spectator')}</p>}
        {messages.map((m) => (
          <div key={m.id} className={`msg ${m.user_id === profile.id ? 'msg-own' : ''}`}>
            <span className="msg-who" style={nameColorStyle(m.name_color)}>{m.username}</span>
            <span className="msg-body">{m.body}</span>
          </div>
        ))}
        <div ref={endRef} />
      </div>
      <form className="side-foot" onSubmit={send}>
        <input
          value={body}
          onChange={(e) => setBody(e.target.value)}
          placeholder={t('chat.placeholder')}
          maxLength={500}
        />
        <button className="btn small" disabled={!body.trim()}>
          {t('chat.send')}
        </button>
      </form>
    </aside>
  )
}
