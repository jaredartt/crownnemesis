/**
 * "3m ago" and friends, for the notifications bell. Four literal i18n keys
 * (common.timeAgoNow/Minutes/Hours/Days) rather than one key built at
 * runtime -- see the project's own rule on that in en.json's own history --
 * so a search for any of them actually finds where it is used.
 */
type T = (key: string, vars?: Record<string, unknown>) => string

export function timeAgo(iso: string, t: T): string {
  const ms = Date.now() - new Date(iso).getTime()
  const min = Math.floor(ms / 60_000)
  if (min < 1) return t('common.timeAgoNow')
  if (min < 60) return t('common.timeAgoMinutes', { n: min })
  const hr = Math.floor(min / 60)
  if (hr < 24) return t('common.timeAgoHours', { n: hr })
  const days = Math.floor(hr / 24)
  return t('common.timeAgoDays', { n: days })
}
