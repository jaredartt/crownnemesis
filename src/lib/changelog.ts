/**
 * The update log shown in Settings -> "Update log".
 *
 * One entry per thing a player could notice, written for players (not the
 * commit message it came from). `at` is when it shipped (UTC), taken from the
 * git history for everything before this file existed. `icon` is a Tabler icon
 * name (lib/tablerIcons.ts) and `color` a hex that says what kind of change it
 * is -- see the legend below.
 *
 * TO ADD AN ENTRY: append one line at the END of ENTRIES with the current time,
 * written in BOTH English and Spanish (the compiler refuses an entry without both).
 * Order in the file does not matter; the screen sorts newest first.
 *
 * Colours: red = fighting / combat, purple = abilities & effects, green =
 * board & units, blue = menus / interface / sound, pink = card looks & art,
 * gold = ranked, tournaments & rewards, orange = social & modes, teal =
 * bots, tools & behind the scenes.
 */
export type ChangeEntry = {
  at: string
  title: string
  body: string
  /** Spanish. Required on every entry: the update log is bilingual, always. */
  titleEs: string
  bodyEs: string
  icon: string
  color: string
}

const RED = '#e5484d', PURPLE = '#8e4ec6', GREEN = '#2e9e5b', BLUE = '#2f6fe4',
  PINK = '#e5589b', GOLD = '#d99a1c', ORANGE = '#f0803c', TEAL = '#12a594'

const e = (
  at: string, icon: string, color: string,
  title: string, body: string, titleEs: string, bodyEs: string,
): ChangeEntry =>
  ({ at: `2026-${at.slice(0, 5)}T${at.slice(6)}:00Z`, title, body, titleEs, bodyEs, icon, color })

// Format: e('MM-DD HH:MM', icon, colour, title, body, tituloEs, cuerpoEs)
// Every entry needs its Spanish title and body (the last two arguments).
export const ENTRIES: ChangeEntry[] = [
  e('09-03 19:25', 'swords', RED, 'The first battle', 'Crown Nemesis begins: online rooms and a placeholder board to fight on.', 'La primera batalla', 'Empieza Crown Nemesis: salas en línea y un tablero provisional donde pelear.'),
  e('09-04 10:40', 'sword', RED, 'Counterattacks', 'Hits get answered, attacks animate, and a Smash-style action menu appears.', 'Contraataques', 'Los golpes se responden, los ataques se animan y aparece un menú de acciones al estilo Smash.'),
  e('09-04 12:00', 'ladder', GOLD, 'Ladder and rematches', 'A hidden rating, a visible ladder, results that outlive the room, and rematch invites.', 'Clasificación y revanchas', 'Una puntuación oculta, una clasificación visible, resultados que sobreviven a la sala e invitaciones de revancha.'),
  e('09-05 07:44', 'star', PINK, 'The mark', 'The logo, favicon and app icons arrive.', 'La marca', 'Llegan el logo, el favicon y los iconos de la app.'),
  e('09-05 12:57', 'tree', GREEN, 'Units, terrain and deployment', 'Real units, trees on the board, decks, and a blind deployment phase.', 'Unidades, terreno y despliegue', 'Unidades de verdad, árboles en el tablero, mazos y una fase de despliegue a ciegas.'),
  e('09-05 20:39', 'robot', TEAL, 'Bots and the queue', 'A bot to practise against, and a ranked queue to climb.', 'Bots y la cola', 'Un bot con el que practicar y una cola clasificatoria para ir subiendo.'),
  e('09-06 12:46', 'cards', PURPLE, 'Eight characters', 'Each with something only it can do.', 'Ocho personajes', 'Cada uno con algo que solo él puede hacer.'),
  e('09-06 13:58', 'cards', PINK, 'The card, as printed', 'Cards drawn the way they would look on paper, with a pinned preview.', 'La carta, tal como se imprime', 'Cartas dibujadas como se verían en papel, con vista previa fijada.'),
  e('09-07 07:28', 'palette', BLUE, 'A menu made of pictures', 'The main menu becomes artwork, and you pick your roster by face.', 'Un menú hecho de imágenes', 'El menú principal se convierte en ilustración y eliges tu plantel por la cara.'),
  e('09-07 13:19', 'volume', BLUE, 'Sound and settings', 'Profile icons, a settings panel, UI sounds, battle sound effects and reduce-motion.', 'Sonido y ajustes', 'Iconos de perfil, un panel de ajustes, sonidos de interfaz, efectos de batalla y reducir movimiento.'),
  e('09-11 11:57', 'swords', RED, 'Combat rebuilt', 'A turn is now two goes, with movement arrows, the opponent\'s pointer and blow-by-blow fights.', 'Combate rehecho', 'Un turno ahora son dos jugadas, con flechas de movimiento, el puntero del rival y peleas golpe a golpe.'),
  e('09-11 13:20', 'moon', BLUE, 'Dark theme', 'Your settings follow your account, and the game gets a dark theme.', 'Tema oscuro', 'Tus ajustes siguen a tu cuenta y el juego estrena tema oscuro.'),
  e('09-11 18:42', 'world', BLUE, 'Spanish', 'The whole game, in Spanish.', 'Español', 'Todo el juego, en español.'),
  e('09-11 19:55', 'building-castle', ORANGE, 'Ten kingdoms', 'Build your five-card army from ten different kingdoms.', 'Diez reinos', 'Arma tu ejército de cinco cartas con diez reinos distintos.'),
  e('09-12 14:44', 'trophy', GOLD, 'Tournaments', 'Brackets, sign-ups and a tournament page.', 'Torneos', 'Cuadros, inscripciones y una página de torneos.'),
  e('09-12 16:57', 'wand', PURPLE, 'Abilities', 'Every character gets an ability button, powered by a flexible ability engine.', 'Habilidades', 'Cada personaje recibe un botón de habilidad, impulsado por un motor de habilidades flexible.'),
  e('09-12 20:10', 'flame', PURPLE, 'Burn, poison and stun', 'Three status effects that change how a fight plays out.', 'Quemadura, veneno y aturdimiento', 'Tres estados que cambian el rumbo de una pelea.'),
  e('09-12 20:31', 'building-fortress', GREEN, 'Things on the board', 'Structures such as walls, bombs and tornadoes that you can place.', 'Cosas en el tablero', 'Estructuras como muros, bombas y tornados que puedes colocar.'),
  e('09-17 08:27', 'users', ORANGE, 'Battle Royale', 'A four-player mode, with away detection for players who drop.', 'Battle Royale', 'Un modo de cuatro jugadores, con detección de ausencia para quien se desconecta.'),
  e('09-21 20:32', 'filter', BLUE, 'Search your roster', 'My Kingdom gets name search, a class filter and sorting.', 'Busca en tu plantel', 'Mi Reino gana búsqueda por nombre, filtro por clase y orden.'),
  e('09-22 20:39', 'menu-2', BLUE, 'A new front menu', 'A Play hub, edge-to-edge tiles and artwork that floats as you hover.', 'Un menú principal nuevo', 'Un centro de Jugar, losetas de borde a borde e ilustraciones que flotan al pasar el cursor.'),
  e('09-23 11:09', 'movie', PINK, 'A proper match opening', 'Get ready, VS, the board builds tile by tile and the cards land.', 'Una apertura de partida como se debe', 'Prepárate, VS, el tablero se arma loseta a loseta y las cartas aterrizan.'),
  e('09-23 11:29', 'book', PINK, 'Comics', 'A Comics page with the story behind the board.', 'Cómics', 'Una página de Cómics con la historia detrás del tablero.'),
  e('09-23 16:32', 'ladder', GOLD, 'Real ratings', 'The tiered ladder gives way to a visible rating and proper matchmaking.', 'Puntuaciones de verdad', 'La clasificación por rangos cede ante una puntuación visible y un emparejamiento como es debido.'),
  e('09-24 05:54', 'pointer', BLUE, 'Action menu icons', 'Every action has an icon, and a greyed-out button tells you why.', 'Iconos en el menú de acciones', 'Cada acción tiene su icono, y un botón atenuado te dice por qué.'),
  e('09-24 17:47', 'user-plus', ORANGE, 'Friends', 'Player cards, a friends page, and invite cooldowns.', 'Amigos', 'Tarjetas de jugador, una página de amigos y esperas entre invitaciones.'),
  e('09-24 18:04', 'robot', TEAL, 'Ranked bot fallback', 'If no real opponent turns up, a bot steps in.', 'Bot de reserva en clasificatoria', 'Si no aparece un rival real, entra un bot.'),
  e('09-24 19:18', 'skull', RED, 'Death animations', 'Every unit that falls now goes down with an animation.', 'Animaciones de muerte', 'Cada unidad que cae ahora se va con una animación.'),
  e('09-25 07:50', 'shield', GREEN, 'Smarter Defend', 'Defend can now be aimed at yourself, an ally, an enemy or a structure.', 'Defender más inteligente', 'Defender ahora puede dirigirse a ti mismo, a un aliado, a un enemigo o a una estructura.'),
  e('09-25 11:04', 'bolt', ORANGE, 'Parry and crit flashes', 'A colour band over the fight scene when a blow is parried or critical.', 'Destellos de parada y crítico', 'Una franja de color sobre la escena cuando un golpe se para o es crítico.'),
  e('09-26 08:55', 'robot', TEAL, 'Bot levels', 'Beginner, Intermediate and Expert bots.', 'Niveles de bots', 'Bots principiante, intermedio y experto.'),
  e('09-28 09:08', 'hourglass', RED, '40-turn limit', 'A match that reaches turn 40 ends in a draw.', 'Límite de 40 turnos', 'Una partida que llega al turno 40 termina en empate.'),
  e('09-28 20:21', 'flame', PURPLE, 'Stun blocks more', 'A stunned unit can no longer move or defend either, and poison and burn damage became tunable.', 'El aturdimiento bloquea más', 'Una unidad aturdida ya tampoco puede moverse ni defender, y el daño de veneno y quemadura se volvió ajustable.'),
  e('09-29 13:19', 'book', BLUE, 'Tutorial', 'A first-time interactive lesson, replayable from Settings.', 'Tutorial', 'Una primera lección interactiva, que puedes repetir desde Ajustes.'),
  e('09-30 06:15', 'flag', TEAL, 'Feedback and bug reports', 'Send feedback or report a bug straight from Settings.', 'Comentarios y reportes de errores', 'Envía comentarios o reporta un error directamente desde Ajustes.'),
  e('09-30 07:38', 'flag', ORANGE, 'Flags and profiles', 'Country flags, profile descriptions, and card-usage stats.', 'Banderas y perfiles', 'Banderas de países, descripciones de perfil y estadísticas de uso de cartas.'),
  e('09-30 11:23', 'activity', TEAL, 'Reconnecting', 'A "Reconnecting with opponent..." notice, and the two-missed-turns rule for people who vanish.', 'Reconectando', 'Un aviso de «Reconectando con el rival…» y la regla de dos turnos perdidos para quien desaparece.'),
  e('09-30 13:35', 'stopwatch', RED, 'One clock per turn', 'A single 30-second clock per turn, with ACTIONS LEFT blocks to track it.', 'Un reloj por turno', 'Un único reloj de 30 segundos por turno, con bloques de JUGADAS RESTANTES para seguirlo.'),
  e('09-30 15:41', 'sparkles', PURPLE, 'Ten new ability animations', 'Shockwave, lightning, claw slash, meteor, starburst, light pillar and more.', 'Diez animaciones de habilidad nuevas', 'Onda expansiva, rayo, zarpazo, meteoro, explosión de estrellas, pilar de luz y más.'),
  e('09-30 16:46', 'star', GOLD, 'Levels, XP and skins', 'Earn XP and levels, and unlock avatar frames and name colours.', 'Niveles, XP y aspectos', 'Gana XP y niveles, y desbloquea marcos de avatar y colores de nombre.'),
  e('09-30 20:26', 'shield-lock', TEAL, 'Chat limits', 'Chat is limited to 3 messages every 5 seconds.', 'Límites en el chat', 'El chat se limita a 3 mensajes cada 5 segundos.'),
  e('10-05 20:12', 'coin', GOLD, 'Shop paused', 'The Shop and Crowns are switched off for now, and Tournaments are back on the menu.', 'Tienda en pausa', 'La Tienda y las Coronas se desactivan por ahora, y los Torneos vuelven al menú.'),
  e('10-06 06:28', 'heartbeat', RED, 'New HP bars', 'Flat bars on the token\'s edge, with a damage chunk that drains.', 'Barras de vida nuevas', 'Barras planas en el borde de la ficha, con un trozo de daño que se va vaciando.'),
  e('10-06 06:37', 'brand-google', BLUE, 'Continue with Google', 'Sign in with your Google account.', 'Continuar con Google', 'Inicia sesión con tu cuenta de Google.'),
  e('10-06 06:55', 'activity', GREEN, 'Battle log', 'Icons for each event, bold class-coloured names, and turn dividers.', 'Registro de batalla', 'Iconos para cada evento, nombres en negrita con el color de su clase y separadores de turno.'),
  e('10-07 16:55', 'bell', BLUE, 'Phone notifications', 'Get a push notification on your phone when it matters.', 'Notificaciones en el móvil', 'Recibe una notificación en el móvil cuando importe.'),
  e('10-07 17:30', 'users', ORANGE, 'Royale on phones', 'A mobile overhaul of Battle Royale, with colour-coded opponent HP.', 'Royale en móviles', 'Una renovación móvil de Battle Royale, con la vida de los rivales codificada por colores.'),
  e('10-08 08:00', 'stack-2', BLUE, 'Floating chat and log', 'On desktop, chat and the battle log float beside the board.', 'Chat y registro flotantes', 'En escritorio, el chat y el registro de batalla flotan junto al tablero.'),
  e('10-08 09:09', 'shield-half', RED, 'Parries need reach', 'A unit can only parry an attacker it could actually reach.', 'Parar requiere alcance', 'Una unidad solo puede parar a un atacante al que realmente podría alcanzar.'),
  e('10-09 17:13', 'pointer', BLUE, 'A go, once begun, is finished', 'The action menu stays until you act, Wait or Cancel.', 'Una jugada empezada se termina', 'El menú de acciones se queda hasta que actúes, esperes o canceles.'),
  e('10-09 17:21', 'robot', TEAL, 'Smarter bots', 'Bots no longer play abilities that would hurt their own side.', 'Bots más inteligentes', 'Los bots ya no usan habilidades que perjudicarían a su propio bando.'),
  e('10-09 17:37', 'cards', PINK, 'A new card face', 'Cards redrawn from the print reference, with numbers, ability icons and stat icons.', 'Una cara de carta nueva', 'Cartas redibujadas desde la referencia de impresión, con números, iconos de habilidad e iconos de estadísticas.'),
  e('10-09 20:32', 'palette', PINK, 'Cleaner card text', 'A text-only ability box that grows with its text, and art cropped for print bleed.', 'Texto de carta más limpio', 'Una caja de habilidad solo de texto que crece con su texto, y arte recortado para el sangrado de impresión.'),
  e('10-10 09:55', 'flask-2', TEAL, 'Admin playtest', 'A sandbox where any card or tree can be dropped, with both teams under one hand.', 'Pruebas de administrador', 'Un campo de pruebas donde se puede soltar cualquier carta o árbol, con ambos equipos bajo una sola mano.'),
  e('10-10 10:00', 'cards', PINK, 'Rounder cards', 'Softer card corners, and My Kingdom tiles zoomed in a little.', 'Cartas más redondeadas', 'Esquinas de carta más suaves, y las losetas de Mi Reino con un poco más de zoom.'),
  e('10-10 21:57', 'palette', PINK, 'Joined-up card stats', 'Movement, range and attack sit flush with each other and the ability box.', 'Estadísticas de carta unidas', 'Movimiento, alcance y ataque quedan pegados entre sí y con la caja de habilidad.'),
  e('10-11 08:51', 'zoom-in', BLUE, 'Bigger hover cards', 'On desktop the hovered card is larger and can overlap chat and the log.', 'Cartas más grandes al pasar el cursor', 'En escritorio la carta señalada es más grande y puede tapar el chat y el registro.'),
  e('10-11 09:10', 'sparkles', BLUE, 'Alpha versioning and the update log', 'The game is in alpha, so versions now read 0.x until launch. This log lists everything that has changed.', 'Versión alfa y novedades', 'El juego está en alfa, así que las versiones se leen 0.x hasta el lanzamiento. Este registro lista todo lo que ha cambiado.'),
  e('10-11 10:10', 'user', BLUE, 'Report a player', 'A Report button on every profile card, and a view-profile link for your opponent after a match.', 'Reporta a un jugador', 'Un botón Reportar en cada tarjeta de perfil, y un enlace al perfil de tu rival al terminar una partida.'),
  e('10-11 10:11', 'speakerphone', GOLD, 'Announcements', 'A banner at the top of the menu for news and notices.', 'Anuncios', 'Un aviso en la parte superior del menú para noticias y avisos.'),
  e('10-11 10:12', 'bolt', RED, 'Better playtest', 'Undo, edit any unit\'s numbers, force crits and parries, and save board setups.', 'Mejores pruebas', 'Deshacer, editar los números de cualquier unidad, forzar críticos y paradas, y guardar configuraciones de tablero.'),
  e('10-11 10:13', 'adjustments-horizontal', TEAL, 'Tunable rules', 'The turn clock, goes per turn, turn limit and trees can now be adjusted without an update.', 'Reglas ajustables', 'El reloj de turno, las jugadas por turno, el límite de turnos y los árboles ahora se pueden ajustar sin una actualización.'),
  e('10-11 10:40', 'world', BLUE, 'Update log in Spanish', 'Every entry in this log now reads in Spanish when your language is Spanish.', 'Novedades en español', 'Cada entrada de este registro ahora se lee en español cuando tu idioma es el español.'),
  e('10-11 11:17', 'palette', PINK, 'Tunable look and feel', 'Fight-scene speed, menu animation speed and the HP bar\'s thickness and animation can now be adjusted without an update.', 'Aspecto y sensación ajustables', 'La velocidad de las escenas de pelea, la de las animaciones del menú y el grosor y la animación de la barra de vida ahora se pueden ajustar sin una actualización.'),
  e('10-11 11:19', 'cards', PINK, 'Stats inside the card box', 'Movement, range and attack now sit inside the white box with a margin all round and a small gap between them.', 'Estadísticas dentro de la caja', 'Movimiento, alcance y ataque ahora van dentro de la caja blanca, con margen alrededor y un pequeño espacio entre ellos.'),
  e('10-11 11:33', 'user-circle', BLUE, 'No border option', 'Your avatar frames now start with a "No border" choice. It is the default for new accounts.', 'Opción sin borde', 'Tus marcos de avatar ahora empiezan con la opción "Sin borde". Es la opción por defecto en las cuentas nuevas.'),
  e('10-11 11:36', 'palette', BLUE, 'Frame button is a palette', 'The button next to your profile picture that opens the avatar frames is now a colour palette.', 'Botón de marco en paleta', 'El botón junto a tu foto de perfil que abre los marcos del avatar ahora es una paleta de colores.'),
  e('10-11 11:44', 'trophy', GOLD, 'Bigger faces on the ladder', 'Profile pictures on the ladder are larger and usernames there now use the Lexend font.', 'Caras más grandes en la clasificación', 'Las fotos de perfil en la clasificación son más grandes y los nombres de usuario ahora usan la fuente Lexend.'),
  e('10-11 11:52', 'typography', BLUE, 'Ladder names in Lexend', 'Fixed: usernames on the ladder now really use the Lexend font.', 'Nombres en Lexend en la clasificación', 'Corregido: los nombres de usuario en la clasificación ahora sí usan la fuente Lexend.'),
  e('10-11 12:05', 'trophy', GOLD, 'Podium on the ladder', 'The world\'s top three are now shown in gold, silver and bronze with a larger, bolder name, and every face has a bit more room before its name.', 'Podio en la clasificación', 'Los tres mejores del mundo ahora se muestran en oro, plata y bronce con un nombre más grande y marcado, y cada cara tiene un poco más de espacio antes de su nombre.'),
  e('10-11 12:12', 'trophy', GOLD, 'Podium numbers', 'On the ladder, the rank numbers 1, 2 and 3 are now gold, silver and bronze in a larger, bolder font; names are back to normal.', 'Números del podio', 'En la clasificación, los números 1, 2 y 3 ahora son de oro, plata y bronce con una fuente más grande y marcada; los nombres vuelven a la normalidad.'),
  e('10-11 12:20', 'trophy', GOLD, 'Podium medals', 'On the ladder, ranks 1, 2 and 3 now sit in a gold, silver or bronze circle with a white number.', 'Medallas del podio', 'En la clasificación, los puestos 1, 2 y 3 ahora van en un círculo de oro, plata o bronce con el número en blanco.'),
  e('10-11 12:31', 'palette', GOLD, 'Podium in game colours', 'The ladder\'s top three medals are now yellow, orange and red, from the game\'s own palette.', 'Podio con los colores del juego', 'Las medallas de los tres primeros de la clasificación ahora son amarillo, naranja y rojo, de la paleta del propio juego.'),
]

/** "1s ago", "34 mins ago", "7h ago", "23 days ago", "3 months ago", "1 year ago". */
export function agoShort(iso: string, lang: 'en' | 'es' = 'en', now = Date.now()): string {
  const sec = Math.max(0, Math.floor((now - new Date(iso).getTime()) / 1000))
  const min = Math.floor(sec / 60), hr = Math.floor(min / 60), day = Math.floor(hr / 24)
  const month = Math.floor(day / 30), year = Math.floor(day / 365)
  const es = lang === 'es'
  const pl = (n: number, one: string, many: string) => (n === 1 ? one : many)
  if (sec < 60) return es ? `hace ${sec} s` : `${sec}s ago`
  if (min < 60) return es ? `hace ${min} min` : `${min} ${pl(min, 'min', 'mins')} ago`
  if (hr < 24) return es ? `hace ${hr} h` : `${hr}h ago`
  if (day < 30) return es ? `hace ${day} ${pl(day, 'día', 'días')}` : `${day} ${pl(day, 'day', 'days')} ago`
  if (day < 365) return es ? `hace ${month} ${pl(month, 'mes', 'meses')}` : `${month} ${pl(month, 'month', 'months')} ago`
  return es ? `hace ${year} ${pl(year, 'año', 'años')}` : `${year} ${pl(year, 'year', 'years')} ago`
}
