import { useEffect, useRef, useState } from 'react'
import { supabase } from '../lib/supabase'
import type { Message, Profile } from '../lib/types'
import { useT } from '../lib/i18n'
import { nameColorStyle } from '../lib/nameColors'

interface Props {
  matchId: string
  profile: Profile
  messages: Message[]
  role: 'player' | 'spectator'
  open: boolean
}

export function Chat({ matchId, profile, messages, role, open }: Props) {
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
    const { error } = await supabase.from('match_messages').insert({
      match_id: matchId,
      user_id: profile.id,
      username: profile.username,
      name_color: profile.name_color ?? 'blue',
      body: text.slice(0, 500),
    })
    if (error) setBody(text) // put it back so nothing is lost
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
          placeholder={t(role === 'spectator' ? 'chat.placeholderSpectator' : 'chat.placeholder')}
          maxLength={500}
        />
        <button className="btn small" disabled={!body.trim()}>
          {t('chat.send')}
        </button>
      </form>
    </aside>
  )
}
