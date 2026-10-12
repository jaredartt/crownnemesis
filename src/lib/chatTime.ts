/** The clock time a chat line was sent, to the second, in the viewer's own time zone and
 *  24-hour style (14:05:09) -- the chat shows it beside every message and join/leave line. */
export function chatTime(iso: string): string {
  const d = new Date(iso)
  if (Number.isNaN(d.getTime())) return ''
  return d.toLocaleTimeString(undefined, {
    hour: '2-digit', minute: '2-digit', second: '2-digit', hour12: false,
  })
}
