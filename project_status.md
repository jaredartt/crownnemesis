# Crown Nemesis — project status

**Last updated:** 2026-09-17
**Read this first if you are a fresh Claude session picking up this project.**

This file is the handoff document. It is the canonical one — it lives in the
repo and is versioned with the code. Keep it current: when you finish a chunk
of work, update the "Where things stand" and "Backlog" sections before the
session ends.

---

## 1. What this is

A competitive 1v1 turn-based tactics card game.

| | |
|---|---|
| Live | https://jaredartt.github.io/tactica/ |
| Repo | `github.com/jaredartt/tactica` (branch `main`) |
| Front end | React 18 + TypeScript + Vite, no UI framework, hand-written CSS |
| Back end | Supabase (Postgres + RLS + Realtime + Auth) |
| Deploy | GitHub Pages, via `./deploy.sh` |
| Owner | Jared (jaredartt@gmail.com) — solo dev, also draws all the art |

### Architecture in one paragraph

**The server is the authority.** There is no INSERT/UPDATE/DELETE policy on
`matches`. Every mutation goes through a `SECURITY DEFINER` plpgsql function.
The client is a renderer that calls RPCs. This is deliberate and must not be
eroded — if you find yourself wanting the client to compute a game outcome,
you are about to introduce a cheat.

Rules and authorisation are split: `cn_move` / `cn_attack` hold the rules and
take an explicit `p_side`; `submit_move` / `submit_attack` are thin shells that
work out who you are and call them. **The bot calls the same `cn_*` functions**,
so it is bound by every rule a player is, and a rule change moves it too.

---

## 2. How to work on this repo

### Where the files are

The work happens **on Jared's machine**, through the device bridge, at:

```
$HOME/mnt/Documents/tactica          # via mcp__remote-devices__device_bash
```

Edit files there in place with `device_bash` (python read-modify-write, or
`sed -i`). **Never re-type a file's contents from earlier tool output** — it may
have been truncated. Only stage files into the cloud container when you need
the Postgres harness or Playwright.

### Deploy

```bash
cd ~/Documents/tactica
TACTICA_REMOTE="https://x-access-token:$(cat ~/.ghtok)@github.com/jaredartt/tactica.git" ./deploy.sh
```

`deploy.sh` builds to a `mktemp -d` on purpose: Vite cannot unlink stale assets
inside the synced folder. For a plain type/build check use:

```bash
npx tsc -b && npx vite build --outDir "$(mktemp -d)" --emptyOutDir
```

### Moving files onto the device

`device_commit_files` to a path that ALREADY EXISTS in the synced folder does
not always land -- it reports success and the old bytes stay. It bit twice in
one session: a rebuilt `mksite.py` and a rebuilt `src.tgz` both silently kept
their previous contents, and the second one cost a full build-and-measure round
against code that had not changed. **Commit to a NEW filename every time**
(`src-cards.tgz`, `src-cards2.tgz`) and check the md5 on the device before
trusting it. The same folder cannot unlink, which is the likely cause and is
also why `tar x` over an existing tree fails with "File exists" -- extract to
`$HOME/tmpsrc` outside the mount and `cp -R` in, which truncates in place.

### The git lock dance

`rm` fails inside the synced Documents folder, so git's lock files cannot be
removed normally. Before **every** git command:

```bash
mkdir -p .git/_stale && mv .git/*.lock .git/_stale/ 2>/dev/null
```

Files you need to delete go to `_to_delete/` (already gitignored) — or ask for
delete permission via `device_request_delete_permission`.

### The SQL test harness (cloud container)

```bash
export PGBIN=/usr/lib/postgresql/16/bin
su pg -c "$PGBIN/pg_ctl -D /home/claude/pgdata -o \"-k /home/claude/pgsock -p 5455 -c listen_addresses=''\" -l /tmp/pg.log -w start"
cd /home/claude/cn && ./t.sh 01_rules.sql 02_presence.sql 03_ladder.sql 04_roster.sql \
                             05_idle.sql 06_bot_ranked.sql 07_abilities.sql 08_profile.sql
```

`sync.sh` copies staged migrations/tests in; `reset.sh` rebuilds the database.
Postgres must run as the `pg` user, not root. Stage files first with
`device_stage_files` so `/mnt/user-data/uploads/Documents/tactica/...` is fresh.

**Current: 779 assertions, all green.** `09_combat.sql` is the Phase A file;
`10_board.sql` is Phase B's, `11_swings.sql` and `12_clock.sql` are
Phase C's, and `13_settings.sql`, `14_ability_es.sql`, `15_kingdoms.sql`,
`16_admin.sql` and `17_trio.sql` are Phase D's, and `18_ranked_blind.sql`
is a bug fix of its own, `19_tournaments.sql` is Phase E's, `20_toast.sql` is a bug fix of its own, `21_reach.sql` is 0030's, `22_auras.sql` is F1's, `23_ghosts.sql` is 0032's, `24_abilities.sql` is F3's, `25_effects.sql` is F2's, `26_summons.sql` is F4's, `27_the_throw.sql` is F5's, `28_the_swamp.sql` is F6's, and `29_allies_and_flight.sql` is G's. Run the whole thing with `./supabase/tests/run.sh`.

**A test that passes on luck is a test that fails on luck.** `12_clock.sql` was
flaky at about one run in two, and had been since the day it was written:
`t_match()` lays eight trees at RANDOM, and the "a move does not touch the
clock" step walks a unit from (2,2) to (3,2) -- which fails outright whenever a
tree happened to be standing there. `09_combat.sql` clears the trees for
exactly this reason; `12_clock.sql` never did. One line, `t_trees(:'m','[]')`,
and six runs out of six. Worth checking in any new file that calls `t_match()`
and then moves anything.

That script has now had **three** silent-failure bugs, which is worth saying out
loud: if a test run ever looks too quiet, suspect the runner before you suspect
the tests.

1. It created no database while `_helpers.sql` pinned its GUCs with
   `alter database t`, and every psql sent stderr to /dev/null -- so the run
   died with no message at all.
2. It globbed `0[1-9]*`, which would have skipped `10_board.sql` without a
   word, and a skipped file looks exactly like a passing one.
3. The capture line had no `|| true`. With `set -e` and `pipefail`, psql
   exiting non-zero on the first failed assertion killed the script *inside the
   command substitution* -- before the `echo` that prints what it captured. A
   failing file printed its own name and then nothing, and the run ended with
   no verdict. This is how `12_clock.sql` appeared to contain no assertions
   while it was in fact failing one. Fixed.

Parry and crit are 5% rolls, so the suite pins them the way it pins the coin
flip: `cn.force_parry` and `cn.force_crit` are set to `'never'` on the test
database in `_helpers.sql`, and a section that wants one turns it on with
`set cn.force_parry = 'always'` and resets it after. A unit at 0% or 100% is
not rolling at all, so the hatch does not reach it -- that is how one test
stands a non-parrying unit up in a forced-parry board.

### The one rule that matters most

> **Verify by measurement, not by eye.**

Every layout or visual claim gets checked in headless Chromium
(`/opt/pw-browsers/chromium`) with real numbers — element rects, computed
styles, `elementFromPoint`. Two of the worst bugs in this project's history
(the board collapsing to zero height, the unit info box shoving the map) were
invisible to reasoning and obvious to a measurement. Where a bug is subtle,
write the test so it **fails on the old code first** — a test that passes on
both versions proves nothing.

### Measuring the client (Playwright)

npm cannot reach the registry from the cloud container (403 on
`registry.npmjs.org`) and Chromium is not on the device, so neither machine can
do this alone. The arrangement that works:

1. Build a harness **on the device**, where `node_modules` already is. A harness
   is an entry that mounts one component with a fabricated `MatchState`.
2. Stage the built html/js/css into the container, serve them with
   `python3 -m http.server`, and drive it with python Playwright against
   `/opt/pw-browsers/chromium-1194/chrome-linux/chrome` -- note the version in
   that path, there is no plain `chromium/` directory.
3. Measure PIXELS: element rects and the board's own tile pitch, never the grid
   styles the component wrote, because the style is the thing under test.

#### Build it WITHOUT a bundler -- `_to_delete/h/mksite.py`

Do not rely on `vite build` for a harness. `node_modules` is inside the synced
folder and therefore **shared between a Mac and a Linux VM**, while rollup and
esbuild each ship a native binary per platform. An `npm install` run on the Mac
prunes it to darwin binaries, and the VM can then run neither -- `Cannot find
module '@rollup/rollup-linux-arm64-gnu'`, and `Exec format error` from esbuild.
This has happened once already and will happen again on any `npm install`.

`tsc` is pure JavaScript and always works, so the harness is built from tsc
output instead. `_to_delete/h/mksite.py` (gone with `_to_delete`; rebuild it
from this description) does three small jobs:

1. tsc emits `from '../lib/cine'`; a browser needs `../lib/cine.js`.
2. tsc emits `import '../styles.css'`, which is not a module -- strip it and
   `<link>` the stylesheet in the page. Also replace `import.meta.env.BASE_URL`,
   which is Vite's and undefined anywhere else.
3. `react`, `react/jsx-runtime` and `react-dom/client` are bare specifiers. Load
   React's UMD builds from `node_modules/react*/umd/` as plain scripts and point
   an **import map** at three shims that re-export the globals. Read the shim's
   export list off the installed React with
   `node -e "Object.keys(require('react'))"` rather than writing it by hand -- a
   hand-written list is wrong the first time a dependency imports a hook nobody
   thought of, which is exactly how it failed once, on `useSyncExternalStore`.

**React 19 ships no UMD build**, so job 3 needs a second path and mksite.py now
has one: wrap each CommonJS file in a factory, register it under its own name,
and give them a `require` that resolves among themselves -- about thirty lines,
no native binary, and every React ships CJS. It picks UMD when the files are
there and CJS when they are not, and **prints which**, because "the harness ran
against a different React from the app" should never have to be deduced from a
symptom. This matters on a machine that has React 19 installed globally and no
way to `npm install` React 18 (the cloud container's registry access is
restricted), which is exactly where this came up.

The Supabase shim is no longer inert either. It records every `rpc` call on
`window.__RPC` and answers from `window.__RPC_REPLY`, so a test can assert what
WENT OUT as well as what came back -- which for Kingdoms is most of the point.

To restore the native binaries instead, on the Mac:
`npm install --no-save --force @rollup/rollup-linux-arm64-gnu@$(node -p "require('rollup/package.json').version") @esbuild/linux-arm64@$(node -p "require('esbuild/package.json').version")`.
`--force` is needed because npm's `--cpu`/`--os` filter dependencies but still
platform-check a package you name directly.

The Kingdoms slice was checked with 131 (`kingharness.tsx` + `kcheck.cjs`,
`lobbyharness.tsx` + `lcheck.cjs`), against nine mutants rather than against
the old code -- see Phase D below for why and for the list. The card slice
added 78 more (`cardharness.tsx` + `ccheck.cjs`), and those DO run against the
previous commit, where 48 of them fail; the purple words took that file to 124
and added 116 in node (`kwcheck.cjs`); the admin editor took the lobby suite
from 25 to 68. **294 browser assertions and 116 in node**, all told.

**The Supabase shim in `mksite.py` is a small fake server now**, not an inert
stub: it records every rpc, insert, update and storage upload on `window.__DB`,
answers from `window.__RPC_REPLY`, can be made to refuse with
`window.__DB_ERR`, and -- since the card editor needed it -- actually APPLIES
`.eq()` filters rather than handing the same rows to every caller. Most of what
is worth asserting about an editor is which calls went out, not what was
drawn.

Phase C's client was checked with 85 browser assertions (the takeover, the
beats and their captions, the reductions that are named and the ones that are
not, a parry chain where every flash has to be a fresh element, the falling,
skipping, phone widths, reduce-motion, and the queue and the bot hold from
inside `Board`) plus 400 random fights in node. Note that most of it is NEW
surface, so "run it against the old code first" does not apply the way it did
in Phase B -- there was nothing there to regress.

Phase B's client was checked this way -- 109 browser assertions over the flip,
the tints, the half line, the whole menu flow, the budget gates, the pips, the
movement arrow and the opponent's ghost, at 320 / 390 / 768 / 1280 px. Every one
was also run against the previous commit's files first, where they fail. That is
the only thing that proves they are testing anything.

**Not everything needs a browser.** Two things were better checked in node, by
bundling a test with the local esbuild (`node_modules/.bin/esbuild x.ts --bundle
--platform=node --format=cjs`; anything that reaches `supabase.ts` needs
`--define:import.meta.env='{...}'` or it dies on a missing env var at import):

- `pathTo()` against `reachable()` over 400 random boards, 19,200 tiles: every
  route starts on the unit, ends on the tile, steps one square at a time, and
  stands only on tiles `reachable()` agrees with. This is the check that keeps
  the arrow honest.
- The ghost's throttle, on a hand-cranked clock. Worth doing: reading it back
  is what found a real bug, where the dedupe key was stringified WITH the side
  attached on one side of the comparison and without it on the other, so the
  two never matched and every pointer move went down the wire. The rate limiter
  is now `throttler()`, exported from `useGhost.ts` with its clock and its
  timers injected, precisely so it can be tested without a browser.

The harnesses lived in `_to_delete/` and are gone; the recipes above are what to
rebuild them from.

### Security constraints (non-negotiable)

- **Never** handle or enter the Supabase database password.
- **Never** put a `service_role` or secret key in `.env.local` or the repo. The
  `sb_publishable_` anon key is public by design and is fine.
- Do not create accounts or enter passwords on Jared's behalf.
- Jared has given blanket consent for GitHub operations and for using his
  computer. You do not need to ask before pushing or committing.

---

## 3. Where things stand

### Shipped and live

Profile icons + settings panel, UI sounds, reduce-motion, battle sound effects
(11 synthesised sounds — WebAudio, no files), plus everything before that.

### Pushed and live

`afc4f7f`, `c93311a`, `595b32d`, `4c80f8f`, `c74c47d`, `6e0d9b0` are on
`origin/main`. Jared pushed the last two himself on 2026-09-11.

**Pushing from a session is still blocked, and the shape of the block has
changed.** The cloud container can now READ the repo -- `git ls-remote` and
`git clone` over HTTPS both work -- but a push is refused by the git proxy with
`jaredartt/tactica is not in this session's authorized repository set`. That is
a policy denial and not a credentials problem: the repo is rejected before any
credential is read, so it lands identically with a token and with none. The
device sandbox still gets a proxy 403 on CONNECT and cannot reach GitHub at all.
Two tokens were pasted into chat in earlier sessions trying to solve this and
neither could; both should be treated as burned and rotated.

So the working arrangement is: a session commits, Jared pushes. To lift it, add
the repo to the session's sources. (A session CAN move a commit to where Jared
can push it without going through GitHub: `git bundle create` on the device,
stage the bundle, fetch it in the container. That is how `c74c47d` was checked
against origin.)

**Still not deployed.** `./deploy.sh` force-pushes `gh-pages` and hits the same
wall, so it has to be run from an ordinary terminal.

### What those four commits contain

**`afc4f7f` — "Quick fixes: the blank rematch page, a top bar that stays, and
the roster"**

GitHub was unreachable from the device sandbox (proxy 403 on every attempt,
after having worked earlier the same session). Retry the deploy command above.
It contains:

- **The blank white page on practice rematch — fixed.** Not a crash. Match's
  navigation effect depended on `onGoTo`, which App rebuilt every render, so it
  re-ran every render — and Match re-renders 5×/second off its own clock. Each
  run restarted the wipe, whose swap lands at 310ms, so the swap never ran: the
  white block covered the screen forever. Three independent fixes (stable
  `useCallback` identities, a `wentTo` ref, and `cross()` no longer restarting
  its clock). Regression test reproduces the old failure and passes on the new.
- Top bar (`CROWN NEMESIS` + avatar + name + gear) fixed above all menu layers,
  visible and **interactive** inside every section. Height is `--head-h`.
- My Team → **My Kingdom**. Hover panel now covers the whole rhomboid
  (`inset: 0 -17%` to match the counter-skew). No more phantom all-hovered grid
  on mobile.
- Tokens: blue halo gone; rim is black on both sides and drawn as an **inset
  shadow** rather than a border (that is what closed the white corner slivers —
  a real border gives the art a different inner radius); `border-radius: 11%`;
  no tilt on hover. Move tiles pulse, no centre dot.
- Face picker: captions removed, avatars 80px.
- PWA icon grey gradient: `background_color`/`theme_color` were **already**
  `#ffffff`, so that was not the cause. Chrome had no `maskable` icon and the
  PNGs carry transparency, so it composited them onto its own background. Added
  opaque `icon-maskable-512/192.png` with the mark inside the centre 78%.

### Migrations

`0001`–`0018` are applied in production. Jared ran `0017` and `0018` on
2026-09-11, so the coin flip below is live and the host no longer always opens.

`0019_board_and_actions.sql` is **run in production** as of 2026-09-11, so the
8-tall board, the two-activation turn, Defend and Wait are all live.

`0020_swings.sql` and `0021_cinematic_clock.sql` are **run in production** as of
2026-09-11, so the blow-by-blow record and the paused turn clock are both live.

`0022_settings.sql` is **run in production** as of 2026-09-11.

`0023_ability_es.sql` is **run in production** as of 2026-09-11, so every
live card carries its ability in both languages.

`0024_kingdoms.sql` is **run in production** as of 2026-09-11, so ten kingdoms
are live.

`0025_admin.sql` is **run in production** as of 2026-09-12, and Jared's own
row has `is_admin`, so the card editor is live.

`0026_trio_and_ladder.sql` is **run in production** as of 2026-09-12.

**`0027_blind_ranked.sql` is built and tested (`18_ranked_blind.sql`) but NOT
yet run in production. It is a LIVE BUG FIX and should go out on its own.**

`0028`–`0038` cover tournaments, effects, abilities, summons, the throw and the
rest of Phase F/G — see section 5b for what each phase built. (This handoff
doc's own "Migrations" list was not kept in lockstep with every one of them;
trust `supabase/migrations/` and each file's own header comment over a gap
here.)

**`0039_super_admin.sql`, `0040_card_audio.sql`, `0041_music.sql`,
`0042_menu_sections.sql` are built 2026-09-16 and NOT yet run in production.**
Admin Mode's access lock, the ban flag, per-card audio, the two music
playlists, and the live menu-section table — see the "Admin Mode" writeup in
section 3 for what each one does. Run them in that order.

`0017` is confirmed run, so who opens is now a coin flip in every mode.

`0017` makes who moves first a coin flip in **every** mode (was: host always
first; `0012` only randomised the ranked *seat*). It is spliced from `0008`
rather than rewritten, because `cn_set_ready` is what turns two hidden
half-boards into one live game. `cn.first_side` is the test escape hatch,
pinned per-database in `_helpers.sql`. Measured fair: 149/300.

### Admin Mode — cards, sounds, the live menu, and everyone's account (`0039`–`0042`)

**Built 2026-09-16. Four migrations, all SQL only — NOT yet run in
production.** Paste them into the Supabase SQL Editor in order (`0039` then
`0040` then `0041` then `0042`); each one's last statement is a row of checks
that should all read `true`. Nothing in the client depends on them being run
in any particular order relative to a deploy — every new table read is
`select`-then-fallback, the same defensive shape `useAuth.ts` has used since
0022's `REQUIRED_COLUMNS` — so the client can go out first or the migrations
can, and neither breaks the other. It just means the new tabs show nothing
(or a `does not exist` error surfaced verbatim by the RPC calls, per the
existing `unwrap()` convention) until the SQL has actually run.

**What moved: Admin Mode is no longer a lobby tile.** It used to be `TILES`'s
`admin` entry, gated on `profile.is_admin`. It now opens from a new row at
the bottom of Settings, gated on **both** `profile.is_admin` **and** the
signed-in email being `jaredartt@gmail.com` (`App.tsx`'s `canAdmin`,
threaded down through `Lobby.tsx` to `SettingsCard.tsx`). In practice this is
the same lock `is_admin` always was — nobody else has ever had the flag — but
the new tabs can ban an account and rewrite a stranger's stats, and that is a
harder blast radius than a card's `hp` column, so it gets a harder check. See
`cn_is_super_admin()` in `0039_super_admin.sql`. The existing `cards` and
`art` bucket policies are untouched — still `is_admin` alone — on purpose,
so a working policy was not rewritten for a rule it already satisfies.

Four tabs, one new component each, all under a shell (`AdminPanel.tsx`):

- **Cards** — the existing editor (`AdminCards.tsx`), plus four new upload
  fields (attack / ability / passive / walking) added inline, storing into
  `cards.audio_attack_url` etc. and a new public `audio` storage bucket.
  **These sounds are layered, not switched.** `sfx.ts`'s synthesised set —
  eleven WebAudio functions, no files, shipped since Phase D — is completely
  unchanged; a card with nothing uploaded sounds exactly as it always has.
  `customAudio.ts`'s `playCardSound()` plays alongside the synthesised call
  at the same beat. The mapping from "beat" to "kind" is a judgement call,
  written up where it is made: `Duel.tsx` treats a `hit` swing tagged
  `why: 'ability'` as the ability sound and everything else as attack, and
  treats `burn`/`parry` as passive; `Board.tsx` fires the walk sound on an
  ordinary move (not a deployment placement). Reasonable, not certain — if a
  card's passive sound feels like it fires on the wrong beat, that mapping is
  the first place to look, not a bug in the upload path.
- **Music** (`AdminMusic.tsx`) — two playlists (Menu, Battle) backed by
  `music_tracks` + a `music_settings` singleton for the two shuffle toggles.
  `settings.music`'s slider has had nothing behind it since 0022 ("Nothing to
  play yet", still the string in `en.json` if these migrations have not run);
  `useMusic.ts`'s `useMusicCategory()` is the player, one shared
  `HTMLAudioElement` for the whole app, driven from a single call site in
  `App.tsx` (menu while in the lobby, battle while in a match, silent while
  signed out or banned).
- **Menu** (`AdminMenu.tsx`) — show/hide/reorder the lobby's own tiles, live,
  via `menu_sections`. `Lobby.tsx`'s `TILES` constant still owns the colour,
  the picture and the focus point; this only ever decides `visible` and
  `sort`, folded over `PLAYER_TILES` as `shownTiles`. A tile with no row yet
  (a database that has not run `0042`) stays visible at its usual spot rather
  than vanishing — fail-open, the same choice `useAuth.ts` makes for a
  missing settings column.
- **Users** (`AdminUsers.tsx`) — search by username (`profiles` has been
  readable by any signed-in player since 0001; this is not a new hole), edit
  a stranger's username / avatar / lp / wins / losses / games / streak /
  achievements (new `text[]` column, nothing else writes it yet) through
  `admin_update_profile()`, and ban through `admin_set_banned()`.

**Banning, and its actual, honest limit.** `profiles.is_banned` is a plain
column. `admin_set_banned()` flips it; from there, two independent things
happen and only one of them is instant:

1. `useAuth.ts` watches the banned account's own `profiles` row over Realtime
   (0039 added `profiles` to the publication) and force-calls
   `supabase.auth.signOut()` the moment `is_banned` arrives `true` — this is
   the "kicked to the login screen" the task asked for, and it is genuinely
   fast (a websocket message, not a poll).
2. `side_of()` — the one function nearly every match-mutating RPC in the
   whole codebase calls to ask "who is acting" (`submit_move`, `submit_attack`,
   `end_turn`, all of them, ~30 call sites across 20 files) — now returns
   `null` for a banned account, which every one of those call sites already
   turns into "you are spectating this match". One function, changed once,
   protects the entire match engine without touching those 20 files.

**What is deliberately NOT covered:** `create_match`, `join_match`,
`create_bot_match` and the ranked queue are not ban-gated. Those functions
have each been redefined multiple times across the migration history and
reconstructing their *current* body correctly, from a stale copy, risked
breaking real gameplay logic for a guard that Realtime already makes mostly
academic — a banned player can still be signed out mid-queue before they
land in a new room. If this gap ever matters in practice (a banned account
opening new rooms in the second or two before the signOut arrives), the fix
is to give each of those functions the same one-line `side_of`-style check,
written against whatever their *current* definition actually is at the time.

Full detail, including exactly which columns and functions changed and why,
is in the migration files themselves — they are written to be read, the same
as every migration before them.

**Verified against the full schema, not just read.** `supabase/tests/run.sh`
was used to apply `0001` through `0042` in order against a throwaway local
Postgres and re-run the whole existing suite (`01_rules.sql` through
`29_allies_and_flight.sql`) on top. First pass caught a real bug worth
recording: `0040`'s `cn_check_card()` redefinition was written against
`0025`'s body, which is the exact "splice, never rewrite from memory" mistake
section 7 already warns about — `0030`, `0031` and `0032` had each redefined
that function since, and copying the wrong ancestor would have silently
thrown the reach-repair, the class defaulting and the aura checks away the
moment `0040` ran. Fixed by splicing onto `0032`'s actual body instead; a
second run confirmed it. **Six assertions fail on this exact checkout with
none of `0039`–`0042` applied at all** — `01_rules.sql`'s "eleven units in
the roster" and four cousins, plus `25_effects.sql`'s "ALL TWENTY UNITS OF
THE SPEC ARE PLAYABLE" — which is to say they are pre-existing and not
something this session's changes touched or introduced; the "Current: 779
assertions, all green" line earlier in this section is stale and should not
be trusted without a fresh run. Worth Jared's attention on its own, separate
from Admin Mode.

---

## 4. Decisions already made (do not re-litigate)

| Question | Answer |
|---|---|
| Turn structure | **Pokémon-style.** Player A plays, then player B, and *that* is one turn. `turnNumber` increments after both have played. |
| Counters | Only when the defender **can reach the attacker**. A Range 3 mage shooting from 3 tiles takes no counter from a Range 1 knight. |
| Range shape | **Everything within N tiles, Chebyshev** (diagonals count as 1). Range 2 = every tile 1–2 away, corners included. Single number, no more min–max spans. |
| Build order | Quick fixes → battle rewrite → Fire Emblem animation layer → i18n + dark mode + kingdoms → tournaments last. |
| Translations | **Split.** UI strings in repo JSON (versioned, zero DB reads, code-splittable). Card ability text in the **database** — otherwise every balance tweak needs a deploy, which defeats the live card editor. |
| Card art hosting | **Supabase Storage**, uploaded from the admin panel. Not GitHub-direct: that needs a write token in a public client bundle. Store the **full URL** in `cards.art_url` / `cards.token_url`, never a bare filename — then switching hosts later is a column update, not a rewrite. |
| Deleting cards | **Retire** (`is_active = false`), not hard delete. `deck_of()` already falls back for retired cards, and a real delete would orphan finished matches. |
| Altea Twins | **Dropped for now.** No stat block was ever provided. |
| Battlefield background art | **Dropped for now.** Never attached. |
| Admin Mode's access lock | `profile.is_admin` **and** the signed-in email is `jaredartt@gmail.com` — not `is_admin` alone. See `cn_is_super_admin()` in `0039`. |
| Custom card/music audio | **Layered on top of `sfx.ts`, never a replacement.** The synthesised set stays the baseline for every card and every player; an upload only adds a sound at the same beat. Same `audio` Storage bucket for both (`cards/` and `music/` prefixes). |
| Banning | A column (`is_banned`), not a service-role call — this client has no service-role key to make one with. Enforced by a Realtime-triggered client-side sign-out (fast) plus a `side_of()` check that blocks further match actions (immediate, and reaches every match function through one shared helper). Match **creation** is not gated — see section 3's "Admin Mode" writeup for why that was left out rather than guessed at. |

### Art already identified

- Braided girl in white → **Dorme**
- Crowned figure (pink line art) → **King Stelaris**
- Black-and-white flame character → **the placeholder** (for Velmor, Sarrave, Thalgrim, Nyxara, Zephyra, etc.)
- Effect icons: blue shield = **Defend**, gold sparkles = **Stunned**, purple spiral = **Poisoned**, red = **Burned**

---

## 5. Backlog — the big battle rework

Jared's spec. Phased in the agreed order. **Nothing below is started.**

### Phase A — combat core (SQL) — **DONE, in `0018_combat_core.sql`**

Built, tested (`09_combat.sql`), and waiting to be pasted into the Supabase SQL
editor. Not yet run in production. What it does:

- Counter **always** happens when attacked and the defender can reach back,
  for **50%** of the counter-attacker's roll. Halving it is what let it become
  automatic: trading blows is now the normal shape of a fight rather than a
  punishment for attacking into reach.
- **5% parry** on any attack: blocks it completely, then answers for 50% if the
  parrier can reach what it caught. Parries chain, **capped at 8 swings**
  (`cn_parry_cap()`), which is the only thing that can reach the cap.
- **5% crit**, +50%, on attacks, counters, and post-parry counters.
- Passives cannot be parried. Lium's answer-first is a passive and lands
  through a parry for that reason.
- Damage is a **single number ±5**: `cards.power` is the stat, `dmin`/`dmax`
  are derived from it and are now just the dice. The client prints the single
  number via `unitPower()`, which falls back to the middle of the old band for
  a match that was already in flight when this landed.
- Heals never crit, are never parried, never draw a counter.
- **Damage order**, confirmed by Jared and implemented once in `cn_damage()`:
  base roll → ×1.5 crit → ×0.5 counter → ×(1 + attacker bonuses) →
  ×(1 − defender resists) → ×0.5 if defending → round. Bonuses multiply before
  resists so a 20% bonus and a 20% resist do not cancel exactly. `p_bonus`,
  `p_resist` and `p_defending` are the hooks Phase B and the royal passives
  hang on — nothing passes anything but zero yet.
- **Losing your royal loses the match**, with four of your units still
  standing if that is how it falls.
- **Exactly one royal per kingdom** (Jared's answer), enforced in `set_deck`,
  and `deck_of` falls back to the default for a deck saved before the rule
  existed. `random_deck()` draws the bot's five under the same rule.

Left for the roster rework, and deliberately: **Dereo is the only royal on the
board**, so "exactly one" is a forced pick today. Queen Miah and King Stelaris
need art before they can be added, and the rule had to exist first or every
deck saved in the meantime would be illegal the day they land. Lium keeps his
old answer-first passive *and* gains the doubled rates and parries-all-parries
the spec gives him; the roster rework should split those apart and move
answer-first to Dorme, where it belongs.

### Phase B — turn and board

**Phase B is DONE, both halves.** The server half is `0019_board_and_actions.sql`
(`10_board.sql`, 35 assertions), run in production on 2026-09-11. The client
half is `6e0d9b0` plus the arrow and the ghost below.

Done in `0019`:

- **A turn is two activations.** One activation is one unit's whole go — move,
  then strike, or either alone — and each unit gets at most one per turn, so a
  turn is two *different* units doing something real. Jared's answers: move +
  strike is ONE go, and a unit cannot go twice. The opening player's first turn
  is one activation, not two.
- `cn_begin_act` is the only place the budget is charged, so `cn_move`,
  `cn_attack` and `cn_defend` cannot disagree about what a go costs. State
  carries `acts` (spent this turn) and `active` (the unit mid-go); units carry
  `spent`. Matches already in flight read all three through `coalesce`.
- **Defend**: `submit_defend` raises a guard that halves incoming damage until
  that unit's own next turn — so it is still up while the opponent swings, which
  is the only time it could matter. It costs an activation and ends it. This is
  the first thing to pass `cn_damage`'s `p_defending` anything but false; the
  hook has been sitting there unused since 0018.
- **Wait**: `submit_wait` closes an activation for a unit that moved and does
  not want to strike. Without it a go stays open and the menu has no Cancel.
- "End turn" already worked at any time and still does.
- Board → **8 tall × 6 wide**. The halves are rows again: host holds 0–3, guest
  4–7. Nothing is rotated in the database — the CLIENT flips per player, which
  is the part still to build. `cn_own_side` was dropped and recreated rather
  than replaced, because its parameters now mean y and h (the same reason 0011
  dropped `cn_own_half`).
- **4 trees per side**, none on either home row — which subsumes the
  no-corners rule, since every corner sits in a home row. `10_board.sql` rolls
  the generator a hundred times rather than once, because the placement is
  random and a rule that holds for one layout and not the next is the bug worth
  catching.
- **The bot plays by it.** It always *was* bound — it calls the same `cn_*`
  functions and they refused it — but `bot_step` kept proposing a third action
  until the server raised, which is how 06 and 07 found this. It now skips spent
  units and, once the budget is gone, considers only the unit already mid-go.

**The client half is DONE too.** Three things landed:

- **The action menu.** Clicking one of your units opens Move / Attack / Ability
  / Defend / (Wait) / Cancel on the piece itself, and NOTHING is lit until you
  choose. That last part is the real change: the board used to light the move
  tiles and the crosshairs the instant you selected a unit, which made a tile
  and a target look like alternatives when they are two halves of one go.
  Ability is present and disabled -- leaving the slot out until abilities exist
  would move the other four items under the player's thumb on the day they land.
  Wait appears only for the unit already mid-go, because `submit_wait` takes no
  unit and ends whichever one the SERVER has open. Walking does not close the
  menu: it comes straight back, standing where the unit now stands, with Move
  greyed and the rest still there.
- **The board flip**, in `draw()` / `flipFor()` in `rules.ts`. Here is the part
  that reads backwards until you check the rows: it is the **HOST** who flips,
  not the guest. `cn_own_side` gives the host rows 0-3, so drawn straight the
  host is along the TOP and the guest is already at the bottom where they
  belong. A spectator flips nothing, and the tinted half is therefore always the
  NEAR half rather than "yours" -- which is the honest reading for somebody who
  has no side. It is a half turn and not a mirror: flipping only the rows would
  leave left and right alone, and a spearman advancing up the right of the board
  for one player would be advancing up the left of it for the other.
  Two places convert a coordinate for the screen -- `Board.tsx`, and the hovered
  tree's card in `Match.tsx` -- and both go through `flipFor()`, which is why
  the rule is named rather than written out twice.
- **The goes**, as two rhomboid pips in the turn bar beside the clock, plus the
  count in the hint under the board. One pip on the opening turn, because that
  turn really does have one activation. Nothing on screen used to say this, so
  the server's refusal was the first you heard of the rule.

Also: `spent` and `defending` reach the token. A spent unit greys out -- the
PICTURE greys, not the whole token, or the shield on a defending unit would be
invisible on every unit it matters for -- and a raised guard shows a shield in
the upper left, stacking rightward past the burn icon the way the roster spec
asks for.

**Order of operations, and it matters: `0019` has to be run in production BEFORE
this client is deployed.** The client reads `acts` / `active` / `spent`, calls
`submit_defend` and `submit_wait`, and reads the halves as rows. On a database
still at `0018` those two functions do not exist and the board is still 8 wide
by 6 tall, so Defend and Wait would error and the tints would be drawn across
the wrong axis.

And the last two client pieces, which finish Phase B:

- **The movement arrow.** `pathTo()` in `rules.ts` is `reachable()`'s walk again
  with a predecessor kept for each tile, so the two cannot disagree about where
  a unit may go -- the arrow is a promise about a click and the server keeps or
  breaks it using those rules. Breadth first, so the first route to a tile is a
  shortest one. A flier gets the straight hop, because it is not walking.
  It is drawn Fire Emblem's way: **one piece of arrow per tile**, each an
  ordinary grid item in its own cell, built as "in-edge to middle to out-edge"
  so the straight, the corner, the tail and the shaft of the head are all the
  same two lines with different ends. No pixel arithmetic anywhere -- which is
  deliberate, since screen-rectangle maths is what broke FLIP and the board
  height before. It shows only while Move is the open question.
- **The opponent's pointer**, in `useGhost.ts`. A Realtime BROADCAST channel,
  no database, no migration. Three small fields travel -- the tile under their
  pointer, the unit they picked up, and which menu item they are on -- and the
  receiving client RECOMPUTES the highlights from the shared state with the
  same `reachable()` / `targetsFor()` everything else uses. Sending tiles would
  be more bytes and would go stale in flight.
  Its security model is that none of it is a fact about the game: a cheater can
  lie about where their mouse is, and the prize is that you get a wrong idea
  about where their mouse is. **What must never reach it** is the part to keep
  an eye on, and there are two things: it does not run during **deployment**
  (the half-boards are deliberately unreadable to each other, and a pointer
  would give a setup away one square at a time), and when Mist lands a Rogue
  aiming from inside it must go quiet -- `mute` is the argument waiting for
  that. It is also off against the bot, which has no pointer.

Nothing of Phase B is left.

### Phase C — the battle cinematic

**Phase C is DONE.** The server half is `0020_swings.sql` and
`0021_cinematic_clock.sql` (`11_swings.sql` 38 assertions, `12_clock.sql` 18),
both run in production on 2026-09-11. The client half is `cine.ts` and
`Duel.tsx`.

Jared's two answers that shaped this: the cinematic is a **full takeover** of
the screen, and **the turn clock is paused for it**. There is no off switch for
now -- a full/quick/off setting was offered and deferred to Phase D with the
rest of the settings work.

What `0020` does, and what it deliberately does not: it changes **no rule**.
Not one number is computed differently and no branch is taken differently --
which is why `09_combat.sql` and `10_board.sql` still pass untouched at 63 and
35. All it does is write down what `cn_attack` was already deciding and
throwing away.

The problem it solves is that `fx` reported **sums**, and sums cannot be
un-added. `dmg 30, counter 45, parries 2, chain 4` has many different fights
behind it, and a cinematic built on a guess about which one would narrate blows
that never landed. So the swings are kept in the order they happened and go out
on `fx.swings`. A swing is:

| field | |
|---|---|
| `k` | `hit` / `parry` / `burn` / `down` / `heal` |
| `by`, `at` | unit ids (a tree's id where the target is a tree) |
| `dmg` | what it took off |
| `crit` | the 5% roll came up |
| `counter` | it was an answer, so it was halved |
| `def` | the receiver had a guard up, so it was halved again |
| `first` | it landed BEFORE the blow it answers — Quick Dagger, and only that |
| `why` | `strike` / `counter` / `quick` / `tree` / `mend`, or for a parry `roll` / `all` |

`why` on a parry is the one worth keeping: Lium catching an answer because he
is Lium is not the same event as a 5% roll coming up, and a caption that calls
both of them "parries" is labelling rather than narrating.

`cn_attack` in `0020` is `0019`'s definition with the recording spliced in,
copied out programmatically rather than retyped -- 330 lines of combat rules is
not where to find out whether the `deploy_unit` lesson took.

The test file also pinned down two things worth writing down, because both read
like bugs until you follow the rules through:

- **Lium's catch earns him a free blow.** Catching an answer is a parry, a
  parry answers if the parrier can reach what it caught, and he is standing
  next to it -- so the shape is `hit, parry, hit`, three swings, and the third
  is his. It lands in `riposte`, not `counter`.
- A killed unit leaves the board for good, so the section that kills somebody
  has to kill a unit no later section needs. `09_combat.sql` already had to
  learn this; `11_swings.sql` now does the same thing for the same reason.

### What `0021` does

The cinematic is two to six seconds of a thirty-second turn, so left alone it
would be charged to the attacker's thinking time and the correct way to play
would be to turn it off. A cinematic you are penalised for watching is not a
feature. So `submit_attack` pushes the deadline by exactly `cn_cine_ms()` of
the swings that were just recorded.

Three things about that, each load-bearing:

- **It is in `submit_attack`, not `cn_attack`.** `cn_attack` holds the rules and
  the bot calls it directly; the bot has no screen and no clock, and giving it
  seconds would be giving it nothing. The turn clock is already `submit_*`'s
  business -- that is where "your time ran out" is raised.
- **There is no "give me more time" call to abuse.** The length is computed
  from the server's own record of the fight. The only way to buy a second is to
  make the server play a longer fight, and the only way to do that is to have
  one. Moving and defending buy nothing, and `12_clock.sql` asserts it.
- **It is capped at twelve seconds**, comfortably above the longest fight that
  can happen today (an eight-parry chain), because abilities are coming and one
  that swings fifty times should not hand its owner a minute to think in.

`cn_cine_ms` is mirrored in the client as `cineMs()` in `src/lib/cine.ts`. The
two have to agree: the server is buying time for a picture the client is
drawing, and if the client's picture runs longer than the server's budget the
player loses their turn watching it. Change a beat length in one, change it in
the other.

### The client half

`src/lib/cine.ts` turns the server's record into a **timeline** -- beats with a
clock, a running health total and a sentence each -- and decides nothing. All
of it is pure: no React, no DOM, no clock of its own, which is what lets four
hundred random fights be checked in node rather than in a browser.

`src/components/Duel.tsx` walks that timeline. It takes the whole screen, the
two of them float and lunge, the health drains, a caption box says what
happened and which rule made it happen, and it is skippable on any click or
key.

Things in there that are load-bearing and look like style until they are not:

- **Health is walked FORWARD from a snapshot taken before the exchange**, never
  back-calculated from what survived. Back-calculation works for the living and
  silently invents a number for the dead -- and the dead are what the last beat
  is about. `Board.tsx` is where the cinematic is built for exactly this
  reason: it already keeps the board a moment ago, because a killed unit is
  gone from `state.units` by the time the fx arrives.
- **Almost nothing is a CSS animation on a class.** A CSS animation starts when
  its class arrives and does NOT restart if the class is already there -- and
  consecutive beats of the same kind are the normal case, not the edge one: a
  parry chain is eight parries in a row. So the lunge, the fall and the camera
  shake go through the Web Animations API, and the parry flash, the ring and
  the damage number are keyed by the beat so React hands each one a fresh
  element. The board's FLIP animation is driven this way for the same reason.
- **Exchanges are QUEUED, not replaced.** The bot acts every 650ms and a fight
  takes seconds, so without a queue its second activation would cut its first
  fight off and show you the aftermath of one you never saw. `Board` also
  reports `onWatching`, and `Match` holds the bot back while a fight is on
  screen.
- **`onDone` is held in a ref and kept out of the schedule's dependencies**, and
  the parent's callback is stable as well. A fresh arrow on any re-render would
  tear down every timer and restart the cinematic from the top -- the blank
  rematch page wearing a different hat.
- Hitstop is **inside** a beat rather than added to it, so it costs no clock and
  cannot accumulate.

Still to build, and deliberately left:

- **Per-ability animations** (the fireball travelling, and so on) and
  status-effect animations. Abilities do not exist yet; they arrive with the
  roster rework, and the beat kinds in `cine.ts` are where they will hang.
- A **full / quick / off setting**. Offered and deferred to Phase D with the
  rest of the settings work. Fire Emblem itself ships one, and by turn forty of
  a long match the case for it will make itself.

### Phase D — UI, i18n, kingdoms

Phase D is thirteen loosely-related items rather than one chunk, so it is being
built in slices. Jared picked the order: **settings plumbing and dark mode
first**, because the dark-mode toggle and the language toggle both need
somewhere per-account to live, and doing it first stops the other two each
inventing their own storage.

#### DONE: settings per account, and dark mode

**`0022_settings.sql` is built and tested (`13_settings.sql`, 32 assertions) and
NOT yet run in production.** One `profiles.settings` jsonb column, one
`set_settings(patch)` function, one trigger.

The design worth remembering is **known keys are validated, unknown keys are
kept**. Each half prevents a different failure. Drop unknown keys and a client
one deploy ahead of the database loses every new setting silently -- and that
is a NORMAL state here, because the site deploys instantly while migrations are
pasted in by hand. Keep everything unvalidated and a volume of 40 or a theme of
'bananas' comes back as a broken screen on every device rather than only on the
one that wrote it. It is a PATCH rather than a replacement for a related
reason: settings are exactly the thing somebody has open in two tabs.

On the client, **the account is the truth and localStorage is the cache in
front of it**. Writes go local-first and are pushed up debounced and coalesced
(a finger on a volume slider is thirty changes a second); the account's copy
wins when it arrives, and whatever the account is MISSING is pushed up once --
which is how anybody who had settings in a browser before 0022 keeps them.
`settings` is deliberately NOT in `useAuth`'s `REQUIRED_COLUMNS`: a database
that has not run 0022 should still let you play, with the cache doing exactly
what it did before.

**Dark mode.** The theme is resolved in JavaScript and stamped on `<html>` as
`data-theme`, so a CSS rule has exactly one question to ask -- 'system' never
reaches the stylesheet. There is an inline script in `index.html` that reads
the same localStorage cache before first paint, because a white flash in front
of somebody who chose dark is the one thing a dark mode must not do.

Two things the measuring settled, and both went against the first instinct:

- **The side colours do not move between themes.** Lifting `--you` for a dark
  background reads better as a line or a tint, and it wrecked the thing they
  are mostly used for -- a SURFACE with white type on it. White-on-blue went
  from 5.9 to 3.2, worse than the same nameplate in light. So they stay put.
  What a brand colour cannot do on near-black is be small text, which is what
  `--you-ink` is for: the same blue, lifted, used only where the blue IS the
  text.
- **A card's `accent` comes out of the database** and was chosen against white;
  some land at 3.8 on near-black. In dark they are mixed toward the page's ink,
  which keeps the card its own colour and the name readable. Light leaves them
  exactly as the card author set them.

Contrast is measured, not eyeballed: every text node's computed colour against
its effective background, composited through transparency, as a WCAG ratio.
**Dark has zero failures. Light has three** -- `.vs`, `.orline` and `.savemark`
-- and all three predate this work. They are listed in the test rather than
silently tolerated: each is a quiet label the palette deliberately keeps quiet,
and changing them is a decision about the brand rather than about dark mode.
**Still open for Jared**, if he wants them lifted.

#### DONE: Spanish

**UI strings** are `src/i18n/en.json` and `es.json`, reached through
`src/lib/i18n.ts`. English is bundled because it is the fallback and a fallback
has to be there before anything is fetched; Spanish is a dynamic import.
`primeLang()` runs at startup so the first paint is not English-then-Spanish. A
missing key renders its own NAME rather than an empty space -- `lobby.play` on
screen is a bug reporting itself, and a blank is a layout that looks fine and
says nothing.

**215 keys, and the checker is the point.** `_to_delete/i18ncheck.cjs` (gone
with `_to_delete`; rebuild it) asserts four things: the same keys both ways,
the same `{holes}` in the same strings, nothing empty and nothing identical in
both languages unless it is on a short list of things that really are, and --
the one that matters -- **every key the CODE asks for exists**. A translation
rots quietly: a key added to English and never to Spanish is hidden by the
fallback and reads fine to the person who wrote it.

**Ability text is in the database**, `cards.ability` (English) and the new
`cards.ability_es`. There is no `ability_en`: `ability` IS the English one and
renaming a column `cn_army`, `deck_of` and `random_deck` all read, to gain a
suffix, is a migration that can only break things. The client looks the text up
LIVE by slug through `useCards()` rather than reading the snapshot in
`matches.state` -- units are snapshotted at deploy and that is right for stats,
but a snapshot cannot hold a translation written after the match began, and
nobody is disadvantaged by a clearer sentence.

**0023 REPLACES the ability prose rather than translating it.** Jared's
instruction was to use what he wrote, in both languages, so both columns are
set from the roster spec in section 6 -- extracted from this file rather than
retyped, with only the `**A:**` / `**P:**` markers stripped (they say whether a
thing is an Ability or a Passive, the Spanish table has no equivalent, and
keeping them would have the two languages saying different amounts).

That replaces prose describing what the engine does today ("Answers a blow from
one tile away or from two") with the spec's description of what each unit is
DESIGNED to do -- and most of those abilities are not built. Dione & Grifo
deals no 15 to everything nearby; Mako plants no bomb. **From 0023 until the
roster rework, a card's text is a promise rather than a description.** That is
deliberate and it is Jared's call; it is written down so nobody later reads it
as a bug.

**The spec's STATS also differ from the live roster**, and 0023 does not touch
them. Lium is 80 hit points here against the spec's 85; Dereo is a 70-point
unit against the spec's 110-point Royal. `14_ability_es.sql` asserts the LIVE
numbers precisely so that a migration claiming to translate cards cannot
quietly retune eleven of them. The stats are the roster rework's business.

Two things the measuring caught that reading did not:

- The theme segment built its key as `settings.theme${value}`, which for a
  value of 'system' asked for `settings.themeSystem` while the dictionary says
  `themeAuto` -- so the button rendered its own key on screen. **No amount of
  checking the dictionaries against each other could see it**, because a
  constructed key is invisible to a search. The keys are written out now.
- A test assertion of mine borrowed Lium's hit points from the spec rather than
  the database, which is how the stat divergence above was found at all.

#### DONE (server half): kingdoms

**`0024_kingdoms.sql` is built and tested but NOT yet run in production.** Two
columns -- `profiles.kingdoms` jsonb (a list of `{id, name, icon, deck}`) and
`profiles.kingdom` text (the selected id) -- plus `save_kingdom`,
`delete_kingdom`, `select_kingdom`, a `cn_clean_kingdoms` cleaner on a trigger,
and `selected_deck()`. `deck_of()` and `set_deck()` are spliced from `0018`.

A list rather than a table, for the same reason settings is a blob rather than
a column each: ten short rows that only their owner reads, always read
together, never joined against anything.

**AN INCOMPLETE KINGDOM IS LEGAL, and that is the whole design.** With one deck
"a team saves itself the moment it is a team" worked. With ten it does not:
building a second kingdom means sitting at one, two, three cards for as long as
it takes to choose, and a store that will not hold that is a store that forgets
what you were doing every time you leave the page. So the column holds a
half-built kingdom happily, and being FIELDABLE is asked separately at the
point of use -- `deck_of()` wants exactly five live cards and exactly one crown
and falls back to the default otherwise. Relaxed editor, strict match.

The one thing `save_kingdom` **does** refuse is a COMPLETE deck that breaks the
royal rule. An incomplete deck has not made its mind up; a complete illegal one
has, and telling somebody the moment they finish beats silently fielding
something else when the match starts.

An unnamed kingdom keeps a **null** name. "Kingdom 3" is words, and which words
they are is a question about the reader's language, so the client answers it --
a default written into the database would be English in a Spanish account
forever.

`profiles.deck` is kept in step rather than retired, written only ever
alongside the kingdoms list. Everything still reading the old column keeps
getting the right answer, `set_deck` writes the SELECTED kingdom, and a client
one deploy behind keeps working. `selected_deck()` falls back to the column for
a profile the backfill missed, which is what `09_combat.sql`'s crownless-deck
assertion now leans on (it empties `kingdoms` alongside the write, because
since 0024 that list is where the truth lives).

#### DONE (client half): kingdoms

`Kingdoms.tsx` (My Kingdom), `KingdomSwitch.tsx` (the pre-battle chip) and
`lib/kingdoms.ts` (the client mirror of 0024's rules). Lobby's team page is now
one line; `Match` takes `onProfile` so the switch works in a waiting room.

**THE ONE RULE THAT DECIDES THE WHOLE SCREEN.** A kingdom becomes the one you
field the moment it IS a kingdom -- five cards and exactly one crown -- whether
that is because you just finished it or because you opened one that already
was. An INCOMPLETE one never displaces a finished one. That is the old "a team
saves itself the moment it is a team" carried up to ten.

The two alternatives were both worse. *Opening a kingdom fields it, full stop*
means wandering into a half-built one silently swaps your army for the default
five -- the exact failure 0024's relaxed-editor/strict-match split exists to
avoid. *A separate "use this one" button* asks a question nobody has: of course
the kingdom you just finished is the one you want. The cost of the rule chosen
is that opening a finished kingdom to look at it does field it, which is why
what you are fielding is written under the grid, on every chip, on the menu
tile, and in the corner of every pre-battle screen.

Other decisions worth not re-litigating:

- **Still no save button.** Everything -- a card, a rename, a mark -- is pushed
  after a 450ms pause, which is also what makes a burst of taps one write.
- **The select waits for the save.** `select_kingdom` on an id the server has
  never seen does not fail; the trigger REPOINTS the selection at the first
  kingdom. So a select that overtakes its own save leaves somebody fielding a
  different army from the one they just built, silently. There is a browser
  assertion for this and it is the one that survived the first mutant.
- **A blank kingdom is never written.** Tapping "new" and wandering off leaves
  nothing behind; the row appears locally because it is what you are looking
  at, and goes up the moment it has a name or a card.
- **The mark** follows the first card in until somebody picks one on purpose,
  and stops being the mark if its card leaves. Chosen from the cards IN the
  kingdom, which is the only list that means anything before anything is
  picked.
- **The switch is absent with one kingdom.** A switch with one position is not
  a switch. It is on ranked, practice, friends and the friends WAITING ROOM --
  `join_match` builds both armies out of `deck_of()`, so an empty room is the
  last instant this can matter -- and on nothing else.
- **`unreadyText()` writes its four `t()` calls out in full** rather than
  building `'kingdom.' + why`. A constructed key is invisible to the check that
  every key the code asks for exists, and this project has already shipped one
  of those (`settings.themeSystem`).

Measured with **121 browser assertions** (`_to_delete/h/kingharness.tsx` +
`kcheck.cjs`, 102; `lobbyharness.tsx` + `lcheck.cjs`, 19) over the shelf, the
save/field call sequences, the mark, deleting, the switch, Spanish, four widths
and WCAG contrast in both themes. Almost all of it is NEW surface, so "run it
against the old code first" does not apply -- **nine mutants** were used
instead, and each one is named by the assertion that caught it: fielding
without checking readiness, saving a blank, no debounce, a select that does not
wait for its save, an eleventh kingdom, a quieter note (contrast), a mark that
ignores a deliberate choice, a switch that shows for one kingdom, and a menu
tile that names an unfieldable kingdom.

#### DONE: the card

**The illustration is no longer drawn on.** Everything used to be cut into the
picture -- the name band across the top corner, the numbers and the rules strip
over the bottom third -- and the stated budget for that was "how much of the art
is hidden", which came to about half. Nothing is cut into it now: a header
above, the square illustration, two strips below. The card is taller than it is
wide as a result, and that is the point -- this is the only place in the app
where the whole drawing is visible. The rules text gets three lines instead of
two, because it is no longer paying for itself in picture. The gradient scrim
that protected white type from a pale patch of sky is gone with the type.

**Pinned left, pointed-at right.** Selecting a unit holds its card open on the
left; whatever is under the pointer opens on the right; pointing at the pinned
unit itself opens nothing. This replaces yours-left/theirs-right, which read
well until a card was pinned and then two of your OWN units wanted the same
edge and one of them lost. Left and right now mean "the one you chose" and "the
one you are pointing at", which is the comparison anybody with two cards open is
making.

**The pinned card drifts** on a nine-second loop; pointing at it settles it into
a tilt picked at random (within 7 degrees) so the same card caught twice is not
a still frame; clicking holds it flat and clicking again lets it go. The float
is an animation on an inner element and the tilt a transition on the outer one,
which is the only arrangement where both work -- an animation's transform beats
a transition on the same element. Reduce-motion starts it still.

**Long press on a phone.** `useLongPress` in Board.tsx, touch pointers only,
420ms, cancelled by 10px of drift; the card lands in the middle of the screen
for as long as the finger is down. The subtle part, and a real bug found by the
browser suite: a swallowed click must be **stopped**, not merely ignored. The
board's own background handler clears the selection, so a click the token
declines to act on but lets past is a long press that puts the unit down. The
assertion for it needs a unit ALREADY selected -- with nothing selected the
escaped click sets the selection to null, which is what it already was, so the
weaker version of the test passed either way.

**Effect icons** were already upper-left and stacking rightward (0019); nothing
to do there but say so.

**The three light-theme contrast failures are fixed**: `.vs` 1.73 and `.orline`
2.07 were `#c4c4d2` and `--faint`, both now `--muted`; `.savemark` 2.31 was
`--good` on white, and `--good` is a SURFACE colour, so there is now a
`--good-ink` beside `--you-ink` -- the same green taken down until it clears 4.5
on both papers, and identical to `--good` in dark, where the bright green is
already 8.1. Running the suite against the previous commit also turned up two
nobody had measured: the card's role line at 2.78 in light (a hard-coded
`#9a9aa8`, now `--muted`) and its rules strip at **1.18 in dark** -- a white
strip painted with `rgba(255,255,255,0.96)` under `--ink`, which in the dark
theme is near-white type on a near-white band. Both are gone with the rewrite.

**How far a card may reach over the board is bounded, not zero.** The arena is
much narrower than the window -- the chat and the log take most of it -- so on
an ordinary desktop the gap beside the board is about 110px, and a card that
fitted in it would be too small to read. So the card is as wide as the gap down
to a 150px floor, and past the floor it reaches a little way over the OUTER
COLUMN and stops. The bound asserted is one tile: it must never reach the
second column, where things actually happen. `.arena` carries `--cols`/`--rows`
for this, because the cards are the board's siblings and cannot read vars set
on it; the gap formula is the board's own width rule negated, so change one and
change both.

Measured with **78 browser assertions** (`_to_delete/h/cardharness.tsx` +
`ccheck.cjs`), which mounts the REAL Match over a faked row rather than the
cards alone -- the thing being changed is not the card but which card opens
where, and that rule lives in Match. **48 of the 78 fail against 1e92233**,
including every geometry claim and `.vs` at exactly the 1.73 it was reported
at, plus four mutants.

The contrast helper had a bug of its own worth recording: `color-mix()` computes
to `color(srgb 0.46 0.53 0.98)`, components in 0..1, and a parser that only knew
`rgb()` read those as bytes and failed a colour that was fine. It failed SAFE,
which is why it survived two slices unnoticed.

#### DONE: the purple words

**There is no keyword table, and that is the whole design.** The roster spec
settled it in one line -- *"text in parentheses is the tooltip number, not part
of the description; the word immediately before it is the purple keyword"* --
and 0023 wrote the spec's sentences into the database verbatim, brackets and
all. So the ability text is ALREADY marked up, and `lib/keywords.ts` reads the
marks out of it:

    "Slightly (5%->10%) increased parry rates"
     ^^^^^^^^  ^^^^^^^^
     keyword   its number

A hand-kept list of vague words would exist twice over, once per language, and
would need editing every time a card is retuned in the admin panel -- a deploy
to change a number that lives in a row. Reading the marks out of the sentence
costs nothing, works in Spanish without anybody writing any Spanish, and means
a new card arrives with its own tooltips attached.

**The one exception** is a bracket at the END of a sentence, which is left
exactly as written. Lumea's "choose where to throw them (15s limit)." would
otherwise make a keyword of "them".

**The two languages do not always mark the same word**, because the number does
not always sit in the same place. English says "Slight (25%) chance to strike
twice" and Spanish "Leve probabilidad (25%) de atacar dos veces", so one marks
"Slight" and the other "probabilidad". Dione & Grifo goes further: the Spanish
bracket is at the end of its sentence, so that card has a purple word in
English and none in Spanish. Both are right about their own sentence, which is
all a structural rule can promise, and `kwcheck.cjs` pins it.

**The bubble is a portal** and has to be. Every place a keyword appears is
inside something that clips -- the card's rules strip is line-clamped, the strip
under the board is one line with an ellipsis -- and `position: fixed` does not
rescue it either, because the card carries a transform and is therefore the
containing block for its own fixed descendants.

**Pointer events, not mouse events**, and this was a real bug the browser suite
caught rather than something reasoned out in advance. With mouseenter-to-open
and click-to-toggle, a TAP could never open anything: a tap fires a
compatibility mouseenter first, so the bubble was already open by the time the
click arrived and the click closed it again. Pointer events carry `pointerType`,
so a mouse hovers and a finger presses, and each gets the behaviour it actually
has.

**A peeked card now STAYS UP when the finger lifts**, dismissed by the next tap
anywhere else (a scrim catches it, which also keeps that tap off the board).
That is a reversal of what shipped in 5bfb6f7 and it is not cosmetic: a card
you have to keep a finger on is a card under your finger, and -- the reason it
had to change -- tapping a keyword means letting go first, so on a phone the
purple words were unreachable. A second bug fell out of it: the long press's
click-swallow was only ever consumed by a click on the same token, and with a
scrim in the way that click lands elsewhere, so the flag stayed armed and ate
the NEXT ordinary tap on that unit. It is disarmed on the following pointerdown
now.

On the roster grid in My Kingdom the words are coloured but the number stays in
the sentence: the tile there is itself a `<button>`, so a button inside it would
be invalid and its taps would be the tile's taps. A browsing view keeps
everything visible; the reading view is the card.

Measured with **116 node assertions** (`_to_delete/kwcheck.cjs`, over the real
text of all eleven cards in both languages -- it is a pure string function and
belongs in node) plus **124 browser assertions** (`ccheck.cjs`, up from 78),
against five mutants.

#### DONE (server half): the admin card editor

**Most of the editor already existed.** `profiles.is_admin` has been a column
since 0001, the trigger that stops anybody promoting themselves has been there
since 0001, and so has the RLS policy "admins write cards". 0025 adds no
permission and no new door. What it adds is an answer to "what should an admin
be prevented from doing by accident", and the answers matter more than they
look:

- **Retiring the last royal ends the game.** `deck_of` refuses a crownless deck
  and falls back to `default_deck()`; `default_deck()` is the first five by
  sort, crown or no crown; and the win condition asks whether a side still has
  a royal ON THE BOARD. A roster with no royal is a match that cannot end --
  both armies field five commoners and nobody can lose. One `update cards set
  is_active = false` away, and it does not look like a mistake while you make
  it.
- **Dropping below five active cards** makes every deck in every account the
  wrong length at once.
- **A seven-character hex is not a colour.** `--ink: #ecectf4` was a real typo
  in this project's dark palette; an accent goes from this table straight into
  a style attribute and fails silently on screen.

So 0025 is a BEFORE row trigger (repair what can be repaired -- trim, lowercase
-- refuse the rest with a sentence rather than a constraint name) and a
STATEMENT-level AFTER trigger for the two roster-wide facts, which are
questions about the table after the whole update has landed. Plus the `art`
storage bucket, wrapped in a check for the storage schema so the test harness
-- which fakes only what the migrations need -- still applies the file.

**There is deliberately no function that grants admin.** Only `service_role`
can set the flag, which is what the dashboard's SQL editor runs as:
`update public.profiles set is_admin = true where id = '<uuid>'`. Not even an
admin can make another one. A door nobody needs is a door nobody has to defend.

Two existing tests moved with it, and both moves are the guard proving itself.
`01_rules.sql` used to insert a card with no slug to check the RLS wall
refused it -- the slug guard now refuses it first, so the assertion passed for
the wrong reason and it inserts a valid card instead. `04_roster.sql` used to
retire **Dereo**, the only royal, to test the fallback; that is now refused
outright, so it retires Eva.

#### DONE (client half): the admin card editor

`AdminCards.tsx`, reached by an eighth menu tile that is only drawn for an
account with the flag. That is not the lock -- the lock is the RLS policy on
`cards`, on the server -- but a door drawn for everybody is a door everybody
tries.

**In English only, and with a Save button**, and both are deliberate
departures. Everything else in this app goes through `t()` because everything
else is read by players; this is read by one person, who wrote the Spanish, and
forty dictionary keys nobody will ever render in the other language is forty
things to keep in step for no reader. And My Kingdom saves itself because it is
your own team and a mistake costs one tap; this is the roster every match is
built from, and a stray keystroke in a number field should not be live before
you have finished typing it.

**The server's refusals are shown verbatim.** 0025's messages are sentences
written for whoever is editing the card -- "an accent is six hex digits, like
#2f4bff" is more use than anything this screen could say instead.

Retired cards are listed too, struck through: a retired card is the thing you
come here to bring back. Art goes to the `art` bucket under the card's own
slug, and the crop goes to `<slug>-face.<ext>` because that is where
`faceUrl()` looks -- a convention from 0005 that the editor has to keep rather
than re-open. The full art's URL gets a `?v=` cache-buster, because the URL
does not change when the bytes do and an art fix nobody can see is an art fix
nobody made.

Measured with the lobby suite, now **68 assertions** (up from 25), against five
mutants. Two of them found real bugs in the form rather than confirming it:

- The ten flag checkboxes were a wrapping flex row, ran out of room, and their
  labels overflowed into the neighbour. A grid whose tracks cannot go below
  140px fixed it -- **but the first assertion written for it did not catch it**,
  because text that overflows its box does not move the box. Two rectangles can
  sit politely side by side while their contents are drawn across each other.
- The real cause of that, found by measuring rather than by reading: there is a
  global `input { width: 100% }` near the top of the stylesheet, and a checkbox
  in a flex row obeyed it and became **146px wide**, pushing its own label a
  whole grid track to the right. It read as a wrapping bug and it was a width.
  The assertion that catches it is "every child stays inside its own label",
  which is worth stealing for any other form.

#### DONE: the match-feel trio, and the ladder's two columns

**`0026_trio_and_ladder.sql` is built and tested but NOT yet run in
production.** Three small things that needed the same migration, plus the
ladder.

**WHICH FIVE THEY BROUGHT.** Deployment has been blind since 0008 and most of
that blindness is the point: WHERE the archer is standing is the secret the
phase exists to keep. WHICH FIVE never was, and knowing it is what turns the
phase from a guess into a decision. `their_army()` hands back identity and not
one coordinate, only to a player (a spectator gets nothing -- they could
relay it), and only while the match is still deploying.

It **lists what it returns** rather than subtracting `x` and `y`. Subtracting
the two keys that are secret today leaves every key added tomorrow exposed by
default, and the next field on a unit will be added by somebody thinking about
combat rather than about this function. The test asks what keys came out, not
whether `x` was among them, for the same reason.

**"DEFEAT THE KING."** Black, white, two seconds, once per match, at the moment
it becomes one. It costs two seconds of a thirty-second first turn -- which is
real, and is why it is short and why any key or tap takes the rest back. The
alternative, pushing the deadline the way 0021 pays for the cinematic, is a
migration and a round trip to buy back something a player can take by tapping.
It does NOT play for a match joined mid-way: a title card for a film that is
half over.

**FULL / QUICK / OFF.** A `cine` key in the settings blob -- no column, because
0022's cleaner keeps keys it does not recognise, though 0026 validates it now
that it is a known one. `quicken()` in cine.ts is a pure **re-timing** of a
built cinematic: same beats, same captions, same reductions, moved closer
together, with the squaring-up dropped first because it is the part that
carries no information. `off` means no TAKEOVER, not no feedback -- the board's
own lunge, shake and damage numbers are the half that is information and they
stay whichever way the setting points.

**The clock does not change**, and that is written into the migration because
it looks like an oversight. 0021 pushes the deadline by the full cinematic's
length whatever the setting says, so turning it down hands you that time back
as thinking time -- which is exactly what Skip has done since Phase C shipped.
Computing a different deadline per side would leak a preference into a shared
clock to close a hole that is already open on purpose.

**THE LADDER** grows two columns. The leaderboard view never selected
`avatar`, so `LadderRow` has carried that field with nothing behind it since
0016 -- faces at last. And `tournaments`, Phase E's stat, added now so the
table settles its shape once rather than shifting under everybody later; it
reads a dash for everybody until Phase E fills it, because a column of noughts
reads as a broken feature and a column of dashes reads as a thing that has not
happened yet.

Measured with **25 SQL assertions** (`17_trio.sql`, against four mutants) and
the browser suites, now **329** between them -- ccheck 124 to 148, lcheck 68 to
75.

**The fake server learned realtime.** The board deliberately ignores an `fx`
that was already there when it mounted, because joining a match mid-exchange
must not replay it -- so nothing that reacts to a CHANGE could be tested at
all. `mksite.py`'s shim now keeps a channel registry and exposes
`window.__PUSH(channel, payload)`, and the harness wraps that in
`window.__FIGHT()`. That is what made the cinematic setting testable.

#### Still to do in Phase D

Nothing. Phase D is finished.
- Deployment: you can see **which units** the opponent picked (but not where
  they place them).
- Match start: black box, white text, "Defeat the king." in epic motion.
- Admin card editor (Jared's account only): create / edit / **retire** cards,
  upload token + full art to Supabase Storage. Add `profiles.is_admin` + an RLS
  UPDATE policy on `cards`. In-flight matches keep their snapshot because units
  are copied into `matches.state` at deploy — that is correct, not a bug.
- Ladder: new **tournaments** stat; show everyone's avatar.

### A bug that was live for six migrations: ranked deployment was not blind

Found while reading how a match gets created, on the way into Phase E, and it
is worth writing down in full because of HOW it survived.

0008 made deployment secret, and the mechanism is the important part: during
the phase the two armies are **not in `matches.state` at all**. They live in
`match_deploy`, one row per side, behind `my_deploy()` which hands you only
your own. A policy that merely hid the other side would still have put both
armies in a row that both clients poll, and "you can read it out of the network
tab" is not something a competitive mode may say.

0012 rewrote `ranked_tick` to make who-goes-first a coin flip. It built the
match with `cn_place()` -- which writes both armies straight into
`matches.state` -- and never called `cn_open_deploy()`. **So from 0012 until
0027, ranked matches were not blind.** Friends rooms and practice were never
affected; `join_match` and `create_bot_match` both still open a proper
deployment.

It survived because nothing asserted it on that path. `06_bot_ranked.sql`
checks that the queue pairs people and that the coin is fair; every
blind-deployment assertion in the suite was about rooms. `18_ranked_blind.sql`
now asks the question of **all three ways a match can begin**, in one file, on
purpose -- a rule that is only checked on the path somebody happened to think
about is a rule with a date on it.

And one more lesson, from the fix rather than the bug. The first draft of 0027
RETYPED the queue-insert instead of splicing it, and dropped the `joined_at`
clause that stops a tick from restarting your wait. The suite failed in
`06_bot_ranked.sql` -- a file with nothing to do with the change -- on "nor
with a tab that stopped calling in". Splice, never rewrite from memory; this
project's own rule, caught by this project's own tests.

### Phase E — tournaments (its own project)

Friday Tournaments menu tile, bottom-rightmost. Bracket that sizes itself to
the entrant count, spectating any live match in the tournament, winners wait in
a "waiting" state, leaving counts as a loss and advances the nearest-bracket
winner. Open every day for now; Friday-only later.

### Status effects to build

| Effect | Behaviour |
|---|---|
| Burned | Loses 15% HP each time the unit attacks or uses its ability (not its passive) |
| Poisoned | Loses 10% HP each turn |
| Stunned | Cannot attack for a turn |
| Defend | Not an effect, but shares the icon slot: halves incoming damage this turn |

---

## 5b. PHASE F — the roster rework and the ability system (PLANNED, not built)

The roster in section 6 is the design. The eleven cards in the database are
not it: Dereo is a 70-point unit against the spec's 110-point Royal, Wuzu is
120 and 30-42 against 85 and 25, Himanta flies and the spec makes it a Rogue,
and nine of the twenty units do not exist at all. Since 0023 a card's TEXT has
been the spec's and its NUMBERS have not, which is why the file has said for
two phases that "a card's text is a promise rather than a description".

Phase F is where the promise is kept. It is big enough that the only honest way
to do it is in six pieces that each ship on their own.

### The decisions that shape it

Answered by Jared, and they matter more than the ordering:

- **An ability SUBSTITUTES the attack.** One activation is still a unit's whole
  go: move then strike, move then ability, or either alone. A turn might be
  "Card 1 moves and uses its ability; Card 2 moves and attacks", or simply
  "Card 2 defends". Nothing about the two-activation budget changes, which
  means `cn_begin_act` / `cn_end_act` and the turn clock already handle it.
- **Nothing is hidden from either player.** Mako's bomb is planted where both
  players can see it. And **Eva's Mist is redesigned**: instead of making
  allied Rogues invisible, it gives them a **10% chance to avoid all incoming
  attacks** while it lasts. This is the single largest saving in the plan --
  invisibility would have meant the two players seeing DIFFERENT BOARDS, and
  the whole architecture is one state blob that both clients poll. That is a
  phase of its own and it is now not needed.
- **The damage roll stays.** The spec's one DMG number is the middle; the
  engine keeps rolling it plus or minus five.

### F1 · The numbers, the classes and the crowns — DONE

**`0031_roster_numbers.sql` is built and tested (`22_auras.sql`) but NOT
yet run in production.** What it turned out to cost is worth recording: the
migration is one file, and **eleven existing test files had to change**.
Every one of them was a number pinned to the live roster asserting itself --
which is the guard working, not failing. Dereo at 70 hit points, Lium at 80,
Mako crossing three tiles, Wuzu felling a tree in one swing, Himanta gliding
over it, Eva mending 5-15, Sinie unable to reach the far corner of a 6x6
board, "Dereo cannot strike something in its face". The old behaviour is
asserted as GONE rather than deleted wherever the change is a rule change,
so that anybody who brings trampling or a gliding Rogue back finds out here.

Two things the measuring caught that reading would not have. `cn_classes()`
must stay callable by everybody: `cn_check_card` is a plain trigger function,
so revoking it turned a non-admin's refused INSERT into "permission denied
for function cn_classes" instead of the RLS refusal it is meant to be. And
the auras reach into every test that measures an exact number, because every
deck carries a Royal -- `t_noauras()` in the helpers is how a test says it is
measuring arithmetic rather than arithmetic plus a crown.

### F1 · The numbers, the classes and the crowns

One migration, one pass over the client. No new mechanics at all, which is the
point: it is the biggest diff in the phase and the least dangerous.

- `cards.role` becomes a real class -- royal, rogue, knight, mage, flying --
  checked by the card trigger and translated in both languages rather than
  stored as an English word.
- The eleven live cards are restated to the spec's HP, DMG, MOV and RNG. `power`
  is already the single damage number the spec has, so this is data.
- The nine missing units arrive: Queen Miah, King Stelaris, Dorme, Ashvar,
  Velmor, Sarrave, Thalgrim, Nyxara, Zephyra. **Inactive until their ability
  exists** -- shipping a card whose text describes something that does not
  happen is exactly the thing this phase is here to end.
- Movement traits follow the class: Flying flies. `flies` and `tramples` stop
  being per-card flags somebody could set by hand on a Knight.
- **The Royal auras cost almost nothing to build**, which is worth knowing
  before it looks like a big piece of work: `cn_damage` has carried `p_bonus`
  and `p_resist` parameters since 0018 and nothing has ever passed them. Dereo's
  20% resistance to Knights, Miah's 20% more damage to Mages and Stelaris's 50%
  resistance to burn and poison are three call sites, not a new system.
- Three Royals means the one-crown rule in `deck_of` finally has something to
  choose between; it already works.

#### THE FOUR CARDS NOBODY REMEMBERS

**`0032_the_four_ghosts.sql` is built and tested (`23_ghosts.sql`) but NOT yet
run in production.** 0031 went out and two of its own checks read false:
`twenty_units` and `every_card_has_a_real_class`. The roster was fine; the
CHECKS were wrong.

`public.cards` has never held only the roster. **0001 seeds four placeholder
cards** -- Vanguard, Skirmisher, Archer, Bulwark -- under a comment reading
"replace these from the admin panel once it exists", with no slug and no class.
0005 retired them (`where slug is null`) and left them there, because in this
project a card is retired and never deleted. 0005's own six-card roster is
still there too, superseded by 0010 and never removed. The live table holds
about thirty rows, of which twenty are the roster and eleven are playable --
and 0031's counts said `from public.cards` with no WHERE.

**Why nothing caught it, which is the part worth keeping.** The suite runs
0001, so the ghosts are in the test database too -- but **a migration's
verification block is not run by the suite**: `run.sh` sends migration output
to /dev/null, because whether it applies is all that file is asking. And
`04_roster.sql` scopes its assertions to the twenty slugs on purpose, which is
right for asserting a roster and is exactly why it could not see this.

0032 gives every row a class and makes it a rule rather than a tidy-up: the
trigger required a class only on an ACTIVE card, which is how four rows sat
there for thirty-one migrations with no kind at all. An empty class is now
filled in on any write, retired rows included.

**The assertion had to move to `01_rules.sql`**, and that is a lesson of its
own: `16_admin.sql` writes every row in the table on its way past, and the
trigger fills a blank class in on any write -- so asserted anywhere after it,
this would have passed because of a test file rather than because of the
migration. That is not passing, it is being lucky.

### F2 · Burn, poison and stun — DONE, both halves

**`0034_effects.sql` is built and green but NOT YET RUN in production.** It is
the migration that switches the last nine cards on, so nothing of F2 is visible
until it runs.

What it does:

- **One `effects` object** on a unit -- `{"burn": false, "poison": false,
  "stun": 0}` -- replacing the loose `burned` boolean, so a fifth effect is a
  key and not a migration. Every read goes through `cn_has`, `cn_stunned` or
  `cn_afflict`, and the literal lives in exactly one place, `cn_no_effects()`.
  On the client the same rule: `src/lib/effects.ts` and nothing else spells the
  key names, and `isBurning()` is where the pre-0034 `burned` fallback lives.
- **Burn** is 15% of MAXIMUM hit points whenever the unit swings -- attack,
  counter, parry or a swing at a tree -- replacing the flat 5. `cn_burn_pct()`.
- **Poison** is 10% of maximum at the start of the unit's OWN turn, and it can
  finish a unit: `advance_turn` drops anything the tick takes to zero.
  `cn_poison_pct()`.
- **Stun** costs the go. `cn_attack` and `cn_ability` both refuse a stunned
  unit with 'that unit is stunned'; `advance_turn` counts it down. A stunned
  unit may still WALK -- the cyclone takes the sword, not the feet.
- **Stelaris's resistance** lands in `cn_effect_dmg`, which is the only place
  an effect's number is worked out, so his half applies to burn and poison
  alike and to nothing else.
- The five new behaviours: Velmor's `poison_hit` (refuses friendly fire),
  Ashvar's `line_burn` (the target's tile and one beyond, by `sign()` deltas,
  no line-of-sight check because a fireball arcs), Sarrave's `poisonsAdj`,
  Thalgrim's `vsPoisoned` (FLAT, added after every multiplier) and Zephyra's
  `stuns`.
- **The seventh leftover** dies here: `parries` moves off Lium and onto Dorme.
- `default_deck()` is rewritten -- first Royal plus the first four non-royals
  -- because the spec's sort puts three crowns at 1/2/3 and a kingdom holds
  exactly one. The suite caught this the moment the nine cards switched on.
- All nine remaining cards become `is_active = true`.

**The bug this turned up, and the shape of it.** `cn_attack` afflicts its LOCAL
copies (`v_atk`, `v_tgt`) and then rebuilds the unit list from the untouched
`v_st->'units'` snapshot, copying across only hp and the acted flags -- so a
cyclone caught on the counter was computed, logged, and then thrown away. The
fix carries the whole `effects` object back rather than one key at a time,
which is the same discipline that keeps the key names in one file: setting one
key in one branch is exactly how `burned` came to be written in two places and
read in four. Both ends of it are asserted -- the stun on the blow and the stun
on the answer -- and the second of those is the one that catches it.

**The client half.** `src/lib/effects.ts` is the only reader. The board draws a
MARK ROW across the top-left of a token -- guard, fire, rot, cyclone, in that
order, a flex row rather than four absolute positions with hand-tuned offsets,
because the old arrangement nudged the shield sideways with a rule that had to
be rewritten every time a mark was added. The icons are Jared's drawn diamonds
in `public/fx/`, not emoji: an emoji is a different drawing on every platform,
which for a set of four meant four fonts' worth of weight and baseline inside
one row. The token's rim takes the colour of the worst thing on it -- stun,
then burn, then poison, then a raised guard -- and those colours are sampled
out of the icon files rather than eyeballed. Measured at a 96px token: four
marks come to 73.4px of 96, so the worst case still clears the health bar.

A stunned unit lights nothing: `canStrike` and `canAbility` both go false, so a
player finds out by the menu rather than by being told no. `aims` now covers
the three targeted abilities and each one's own target set (`heal_any` any unit
with line of sight, `poison_hit` enemies only with line of sight, `line_burn`
any unit, no line of sight), which is why it is a switch and not the attack's
target list under another name. Four new swing reasons are captioned in both
languages: `steal`, `fire`, `poison`, and the counter-stun rides on the
existing ones.

**Answered:** nothing cures. Burn and poison are permanent until death --
Jared's call, and the reason `cn_ability` has no cure branch.

### F3 · The ability engine — DONE, both halves

**`0033_abilities.sql` is run in production, and the client half is built.**
The two belong together: it adds a swing kind the
cinematic has to narrate (`mist`), and an old client would caption a dodge as
an ordinary blow for nought.

It started with Jared looking at the live game: *"I still don't understand why
Umiro can heal, it's not written in his abilities"* and *"why Mako doesn't
receive counters, what the heck"*. Both were leftovers from 0010, which built
eleven cards out of flavour text -- Umiro a Herbalist, Mako a Bandit whose card
read "Never takes a blow in return". 0023 replaced every card's TEXT with the
spec's and deliberately changed no behaviour; F1 restated the numbers and left
the same gap. **After 0033 no card does anything its own description does not
say.** Five gain what they promised; six lose what they never advertised, and
four of those six are plain fighters until F4, F5 and F6.

**THE ABILITY BUTTON IS ON.** It has sat in the action menu since Phase C,
deliberately empty and disabled, so that switching it on would not move the
other four items under somebody's thumb on the day it landed -- and that is
exactly what it cost to turn on: nothing moved. Its tooltip now says which of
the two "no" it means, because "abilities are not built yet" and "this card
carries a passive" are different news.

**An ability that aims is a mode; one that does not is a button.** Healing
Petals lights its targets and waits, reusing the crosshair machinery the attack
already had. Back to Back and the Mist fire from the menu, because there is
nothing to point at.

**And an ability gets NO cinematic.** The Duel is two fighters facing each
other; an ability is one unit and a crowd. What it gets instead is the board's
own language -- a number off every unit it touched -- which is the half that is
information rather than performance. `fx.hits` is the shape that needed: one
actor, any number of receivers, which an attack never had.

**An ability substitutes the attack**, so `submit_ability` is the same citizen
as `submit_attack` -- same shell, same `cn_begin_act` budget, same clock push --
and `24_abilities.sql` asserts exactly that as hard as it asserts the abilities
themselves.

Two things worth knowing for F4 onwards. **Strike Twice cost almost nothing**
because 0020 made the swing chain uniform: "a second hit when Himanta attacks,
counters or parries" is one branch, because all three are the same thing in
that loop. And **`jsonb_set`'s `create_missing` only creates the LAST step of a
path** -- writing `['mist','host']` into a state with no `mist` key does
nothing at all, silently, which is the worst way a jsonb write can fail. The
mist key is created first, explicitly.

### F3 · The ability engine, and every ability that needs nothing new

`submit_ability(match, unit, target)`, substituting the attack inside the same
activation, on the same clock, through the same authorisation shell as
`submit_attack`. The rules go in `cn_ability`, dispatched on the card, so that
a new card is a row and one handler rather than a rewrite.

Targeting is a small vocabulary rather than a special case per card: nothing,
one unit in range, one tile in range, a line of two, every adjacent tile. The
client reuses the crosshair machinery the attack already has.

What ships with it, because none of it needs a new kind of thing on the board:

- **Dione & Grifo** — 15 damage to every adjacent tile.
- **Sinie** — heals 30 to one target. (Today Sinie mends everything in range;
  the spec is single-target and bigger.)
- **Velmor** — poisons the target and deals 10.
- **Ashvar** — burns two tiles in a line and deals them 15.
- **Eva** — Mist for two turns: allied Rogues get a 10% chance to avoid all
  incoming attacks. Its ability text changes in English and Spanish with it.
- And the passives that are pure combat arithmetic: **Himanta** (immune to
  parries and crits, 25% to strike twice), **Thalgrim** (+25 against a poisoned
  target), **Nyxara** (heals for 100% of damage dealt), **Zephyra** (stuns on
  hit), **Wuzu** (5% regeneration each turn), **Sarrave** (poisons every
  adjacent tile at the start of its turn), **Dorme** (always counters before
  the blow lands -- the `first` path already exists for parries), **Lium**
  (already built).

### F4 · Things you put on the board — DONE, both halves

**`0035_summons.sql` is built and green but NOT YET RUN in production.**

`obstacles` stopped meaning "trees" and started meaning objects:
`{id, kind, x, y, hp, maxHp, owner, by, dmg}`. A row written before 0035 has no
`kind` at all and nothing is backfilled: `cn_obj_kind()` reads a missing kind
as 'tree', which is what every one of them is, so no live match changes shape.

| kind | solid? | hp | what it does |
|---|---|---|---|
| tree | yes | 30 | stands there. Tramplers walk through it. |
| wall | yes | 20 | stands there, and nothing walks through it. |
| bomb | no | 15 | whoever steps on it takes its `dmg` (15) and it is spent. |
| tornado | no | 25 | nothing yet — F5 is where it throws people. |

**"Solid" is the whole of it.** A solid object blocks feet and arrows; a
non-solid one blocks neither, which is why you shoot over a trap and walk
round a wall. `cn_obj_solid()` is the only place that list lives, and
`src/lib/objects.ts` is the client's only copy of it. Trample is separately a
rule about TREES and not about everything in the way — a wall summoned to stop
somebody would be no wall at all if Wuzu walked through it — so cn_reach
carries two masks now, `v_tree` (solid) and `v_fell` (tramplable).

**The tile target.** Three abilities put something on a TILE rather than on a
unit, and `submit_ability` has only ever carried one text argument. A target
beginning with '@' is a tile: `'@3,4'`. `cn_tile_target()` is the only parser
and `cn_tile_key()` the only writer, so no caller signature changed anywhere —
and F5 wants the same shape for a throw destination, which is why it is a
convention rather than a hack in one branch. A bare `'2,3'` (how cn_reach has
spelled a tile since 0005) is deliberately NOT one; the '@' is the whole
distinction, and there is an assertion saying so, because no unit id happens
to contain a comma and the guard could otherwise be deleted unnoticed.

**One alive at a time.** "Can resummon if destroyed" is not a cooldown: each
object carries `by`, the id of the unit that made it, and a summoner with one
still standing is refused. Destroying it frees the slot by itself.

**Mako's trap is VISIBLE to both players** — Jared's call, against the spec's
"hidden", because a hidden object on a shared board would need a per-side view
of the state that nothing else in this game has.

**cn_move is now a place a unit can die**, which it never was before: a trap
can finish whoever steps on it, and a crown that walks onto one loses the
match. The ending is wired with the same three statements cn_attack ends with
— `finish_match` when ranked, then status/winner/turn_deadline — because a
match that finishes here has to settle exactly as one that finishes on a blow.

**The client half.** `src/lib/objects.ts` mirrors the vocabulary by name;
`rules.ts` filters `trees` by solidity and gained `fellable` beside it. Board's
`Tree` became `Thing`: a tree stays a crop of the painting because woodland
should read as ground, and for exactly that reason the three summons are drawn
as inline SVG shapes instead — a summoned thing that looked like terrain would
be read as terrain. Each carries its owner's colour (`--you` / `--danger`),
because whose wall it is decides whether it is cover or a problem. A summoner
lights GROUND rather than units, in purple with a crosshair, so an ability that
spends the whole go does not look like a walk you can take back.

### F5 · Lumea's fifteen seconds — DONE, both halves

**`0036_the_throw.sql` is built and green but NOT YET RUN in production.**

An enemy walks into Lumea's tornado and Lumea's controller gets fifteen seconds
to choose where to throw them while everything else waits. The novelty is not
the throw, it is the PENDING: a decision belonging to the side whose turn it is
NOT. Every other rule in this engine asks "is it your turn"; this one asks "is
it your decision".

```
state.pending = {kind:'throw', side, unit, obj, resumeMs}
```

**One clock.** A pending decision does not get a second deadline column. While
one is open, `turn_deadline` IS the decision's deadline, and what the turn had
left is parked in `pending.resumeMs` and given back when the decision closes.
One clock means one realtime push, one countdown on the client, and one thing
for `force_timeout` to look at — which is what "everything else waits" has to
mean if it is to mean anything. The turn does not change hands and is not lost.

**What is blocked: everything.** The guard is in `cn_begin_act`, which every
move, strike, ability and guard already passes through, and separately in
`submit_wait` and `end_turn`, which are the two that do not. Note that the
waiting side is refused with 'not your turn' rather than 'a throw is pending' —
that guard comes first and was already true; `27_the_throw.sql` asserts the
message it actually gives, because a test that tidies away which guard fired
will not notice when the wrong one does.

**The default is nothing.** Fifteen seconds pass and the gale dies down with
the unit where it stood. A default that MOVED somebody would make running the
clock out a move in itself, and a decision you can lose by not making is not a
decision, it is a penalty.

**Rules.** Only an ENEMY tornado takes hold — walking your own unit into your
own gale to be repositioned would make Lumea a taxi. The throw reaches three
tiles (`cn_throw_reach()`; not on any card, so it is a function rather than a
column). No line of sight: a gale throws over things. It will not put somebody
inside a wall or on top of a unit — and a trap is neither, so **you can throw
somebody onto a trap**, which is the best thing in the game. The tornado stays:
it is weather, not a trap.

**And a refactor that earned its place.** 0035 made `cn_move` the first place
in the game where a unit could die and inlined the trap, the crown check and
the settling to do it. The throw is the second, so all three came out into
`cn_spring`, `cn_win_after_death` and `cn_finish`, and `cn_move` was
re-spliced onto them. Two copies of "who won" is how a ranked ladder quietly
stops agreeing with itself.

**The client half.** `state.pending` drives a throw mode in Board: the menu is
suppressed (a menu of five buttons the server would refuse is worse than no
menu), unit clicks are inert, and the only lit tiles are the ones the gale can
reach. A **gale bar** sits over the board saying the same thing to both sides
in different words, with a "Let them go" button for the deciding side; it is
anchored to the end of the board AWAY from the caught piece, the same way the
action menu opens away from the nearest edge, and it eats no clicks of its own
— measured at zero overlap with the lit tiles in both anchorings. The caught
unit turns slowly under a tornado-coloured rim. The countdown is the ordinary
turn clock, because while a decision is open that clock IS the decision's.

### F6 · Umiro's Swamp — DONE, both halves. **PHASE F IS COMPLETE.**

**`0037_the_swamp.sql` is built and green but NOT YET RUN in production.**

"Nearby units cannot use Passives or Abilities." Left until last because it has
to negate every other thing the phase built.

**It is one function.** Written as a condition asked at each of the dozen places
a passive is read, it would be a dozen chances to forget one — and the one
forgotten would be a rule that silently keeps working inside the swamp, which
is the worst kind of bug this codebase can have. So instead: `cn_awake(state,
unit)` returns that unit with its passives GONE if it is standing next to an
Umiro, and every rule goes on reading the fields it always read. The gate is
applied where each fighter is first bound — twice in `cn_attack`, once in
`cn_ability`, twice in `advance_turn`, once inside `cn_aura` — and everything
downstream inherits it, because `v_strk` and `v_recv` are assigned FROM `v_atk`
and `v_tgt`. `src/lib/swamp.ts` is the client's copy, same shape, same reason.

**What it takes:** the ability and what it summons, the royal aura, and every
flag or number implementing a **P:** line — `parryAll`, `parries`, `slippery`,
`twicePct`, `regenPct`, `poisonsAdj`, `stuns`, `vsPoisoned`, `lifestealPct`.

**What it deliberately does not take**, all judgement calls, all written into
the migration's header so a later reader finds the decision and not the symptom:

- *Flight and trampling.* Those are what a CLASS is. A Flying unit that fell
  out of the sky because a Mage stood next to it would read as a bug.
- *The body, the reach and the dice.* Lium's "slightly increased parry and crit
  rates" lives in two NUMBERS on his card rather than a flag, so the swamp takes
  his "parries all parries" and leaves his dice alone.
- *Effects already on a unit.* A burn is not a passive; the swamp is a silence,
  not a cure.
- *Itself.* Two Umiros side by side silence each other, and `swamps` is the one
  field `cn_awake` never strips, so neither stops being a swamp.

**Who it catches:** everybody adjacent, friend and foe alike, exactly as Back to
Back hits every next-door tile. Standing your own Nyxara beside their king is a
decision with a cost — and parking Umiro next to their Stelaris turns off the
burn resistance for their whole side, which is the most useful thing it does.

**A near-miss worth keeping.** `cn_swamped` originally carried an "and not
itself" clause. Mutation testing showed deleting it changed nothing — a unit is
never one tile from itself, so the line read like a rule and tested as nothing.
It was removed and replaced by the case it looked like it was protecting: two
Umiros, asserted.

**Two things 0037 broke on the way in**, both caught by the suite and both
worth knowing: `jsonb_build_object` takes at most 100 arguments and the unit
snapshot was at exactly 100, so the snapshot is now built as two objects
concatenated — and `||` is left-associative, so the second one has to be
parenthesised or it is appended to the units ARRAY as a unit of its own.

**The client half.** `isSwamped`/`awake` in `src/lib/swamp.ts`; `targetsFor`'s
counter and parry warnings became `willCounterOn`/`willParryOn`, which take the
board, because whether that Dorme answers first now depends on who is standing
next to it. The Ability button greys with its own reason — "no ability on this
card", "stunned" and "standing in the swamp" are three different pieces of news.
A green marsh diamond joins the mark row (matching the four Jared drew) and the
token's rim turns green: the swamp is last in the cascade, so it outranks every
other piece of bad news.

**And one silent regression fixed:** the mark row lost its per-kind class when
it went from emoji spans to images in F2, so `.unit-mark-burn` and friends had
been dead CSS ever since. A missing drop-shadow looks like a design choice
rather than a bug, which is why it took a swamp test to notice.

### Still open, and worth answering before F1 rather than during it

- The three Royals are written **A:** in the spec but describe permanent team
  effects. Treating them as passives; they are never activated.
- Does Rogue imply today's "sneak" (never answered by a counter)? Mako has it
  now, and under the spec Mako's slot is spent on the trap instead.
- Burn and poison as a percentage of MAX hit points, not current. Assumed.
- Nothing cures. See F2.

### G · After Phase F — the rules Jared changed while playing

**`0038_allies_flight_crowns.sql` is built and green but NOT YET RUN.**
Three rule changes and four client fixes, all from playing the finished phase.

#### You may strike your own

`cn_attack` refused with 'no friendly fire' unless the attacker carried
`heals` — and since 0033 NOBODY carries `heals`, so the refusal was total and
the mending branch behind it unreachable. An ally in reach is now an ordinary
blow.

It does **not** answer, and does **not** parry. A counter is what somebody does
when an ENEMY attacks them; and a parry is not only a block — it flips the
swing, so a parrying ally would strike back, which is the same rule read
backwards. Both are one `not v_ally` at the right line. Everything else still
applies: the cyclone stuns your ally, the lifesteal drinks from your ally, and
a crown of yours that falls to your own blade loses you the match.

**A bug this turned up:** the rebuild loop at the end of `cn_attack` had an
`if v_ally` branch that kept the target on the board whatever its health,
because the only way to point the function at an ally had been to MEND it and
nobody is mended to death. The first friendly kill left a unit standing at
minus thirty hit points and the match never ended. The two branches were
already identical apart from that — 0034 folded the cure and the new burn into
the target's own effects object — so they are one branch now.

#### Flight is not a pass

`cn_reach` had a branch for fliers that asked only how far away a tile was and
ignored everything on the ground between. Jared: *"Flying class shouldn't jump
over units/structures unless stated in their ability/passive"*, and nothing
states it. Gone, on both sides. `flies` stays on the three cards and is simply
no longer read; what the Flying class keeps is movement 3 and 4 against a
Knight's 1. A card that should genuinely overfly needs a flag that says so —
saying so is the whole of the rule.

#### Every kingdom has exactly one crown

Every route into an army already satisfied this — `set_deck` refuses anything
else, `deck_of` falls back to `default_deck()`, `random_deck()` picks one royal
and four commoners (measured 400/400). "Already satisfied" was the problem: a
property four functions shared rather than a rule the engine held. The check
now lives in `cn_army()`, the one door every army in the game comes through —
the bot's, the ranked pair's, the tournament's, the rematch's.

The kingless bots Jared found are older rows: nothing in the current code can
produce one, and nothing can fix a match already in flight either. 0038's
verification block prints how many exist.

#### Four client fixes

- **The movement arrow had no visible tail.** The first tile of a route is the
  one the unit is standing on, and the unit is drawn over it at a higher
  z-index — so the dot and half-shaft that went there were painted underneath
  the piece. The arrow starts at the SECOND tile now, entering from the edge it
  shares with the unit. Measured at zero arrow pixels behind a token.
- **The result showed before the telling.** The board installed the new state
  the moment it arrived and played the exchange over the top, so for a few
  frames the health bars gave the answer away and a unit that had fallen was
  already gone from the board it was about to fall on. The board now draws the
  PREVIOUS units and objects until the cinematic ends (floor of `FX_MS`, so the
  takeover being switched off does not bring the spoiler back). Only the
  drawing is frozen; every rule still reads `state`, which is moot anyway
  because nobody may act while a fight is on screen.
- **Rhombus particles.** Twelve diamonds thrown out of a blow that landed, on
  the board AND on the struck fighter inside the cinematic (which is where the
  eye is). Two things worth knowing: the direction is baked into an OFFSET and
  not a rotation, because a diamond spun thirty-seven degrees is a square; and
  the distances are `cqw`, not per cent, because a percentage inside
  `translate` is a percentage of the *shard*, which threw every piece ten
  pixels and produced one blob.
- **`lobby.bot`.** The menu showed the literal key. The tile was renamed from
  'practice' to 'bot' and `t(`lobby.${id}`)` followed it silently — a
  CONSTRUCTED key, invisible to a search and to the i18n check, which is the
  exact mistake this project has a rule against. Replaced with a
  `Record<PageId, string>` of literal keys, so a tile without one is now a
  compile error. **Every other constructed key in the app was audited:
  `bot.*`, `tier.*` and `status.*` all resolve.**

## 6. The roster spec

**Classes:** Royal · Rogue · Knight · Mage · Flying
(ES: Realeza · Furtivo · Caballero · Mago · Volador)

Text in parentheses is the **tooltip number**, not part of the description —
the word immediately before it is the purple keyword.

| Unit | Class | HP | DMG | MOV | RNG | Ability / Passive |
|---|---|---|---|---|---|---|
| King Dereo | Royal | 110 | 30 | 1 | 1 | **A:** Grants the team minor (20%) resistance to Knights. |
| Queen Miah | Royal | 110 | 25 | 1 | 1 | **A:** The entire team deals slightly (20%) more damage to Mages. |
| King Stelaris | Royal | 120 | 30 | 1 | 1 | **A:** Grants the team strong (50%) resistance to burn and poison. |
| Dione & Grifo | Knight | 95 | 30 | 1 | 1 | **A:** Back to Back — Deals 15 damage to all nearby (Range 1) tiles. |
| Lium | Knight | 85 | 35 | 1 | 1 | **P:** Always Ready — Slightly (5%→10%) increased parry and crit rates. Parries all parries. |
| Mako | Rogue | 60 | 35 | 2 | 1 | **A:** Improvised Trap — Plants a hidden bomb dealing 15 damage. Can plant another if destroyed. |
| Eva | Rogue | 80 | 20 | 2 | 2 | **A:** Nature's Whisper — Summons Mist for 2 turns. Allied Rogues are invisible. |
| Himanta | Rogue | 70 | 25 | 2 | 1 | **P:** Slippery — Immune to parries and crits. Slight (25%) chance to strike twice. |
| Dorme | Rogue | 65 | 30 | 2 | 2 | **P:** Quick Dagger — Always counters before the attacker's hit lands. |
| Fey | Mage | 85 | 15 | 2 | 3 | **A:** Cursed Wall — Summons an underworld wall with 20 HP. Can resummon if destroyed. |
| Umiro | Mage | 75 | 25 | 1 | 2 | **P:** Swamp Bringer — Nearby units cannot use Passives or Abilities. |
| Sinie | Mage | 65 | 30 | 2 | 3 | **A:** Healing Petals — Heals 30 HP to a target. |
| Ashvar | Mage | 70 | 20 | 2 | 2 | **A:** Fireball — Burns 2 tiles in a line and deals them 15 damage. |
| Velmor | Mage | 70 | 35 | 2 | 2 | **A:** Cursed Blade — Poisons the target and deals 10 damage. |
| Sarrave | Mage | 80 | 15 | 1 | 1 | **P:** At the start of their turn, poisons all adjacent tiles. |
| Thalgrim | Mage | 80 | 15 | 1 | 1 | **P:** Deals an extra 25 damage if the target is poisoned. |
| Nyxara | Mage | 65 | 15 | 2 | 2 | **P:** Cursed Body — Heals for 100% of damage dealt. |
| Wuzu | Flying | 85 | 25 | 3 | 2 | **P:** Regenerative Body — Heals slightly (5%) every turn. |
| Lumea | Flying | 75 | 20 | 4 | 2 | **A:** Gale Summoner — Creates a tornado. If stepped on, choose where to throw them (15s limit). |
| Zephyra | Flying | 65 | 20 | 4 | 1 | **P:** Cyclone — Stuns the target on hit. |

### Spanish ability text

| Unit | ES |
|---|---|
| King Dereo | Otorga al equipo una leve (20%) resistencia contra Caballeros. |
| Queen Miah | Todo el equipo inflige un leve (20%) daño adicional a Magos. |
| King Stelaris | Otorga al equipo gran (50%) resistencia a quemadura y veneno. |
| Dione & Grifo | Espalda con Espalda — Inflige 15 de daño a todas las casillas de alrededor (Rango 1). |
| Lium | Siempre Atento — Probabilidad de bloqueo y crítico levemente (De 5% a 10%) aumentada. Bloquea todos los bloqueos. |
| Mako | Trampa Improvisada — Planta una bomba oculta de 15 de daño. Puede plantar otra si esta se destruye. |
| Eva | Susurro Natural — Invoca Niebla por 2 turnos. Los aliados Furtivos son invisibles dentro. |
| Himanta | Escurridizo — Inmune a bloqueos y críticos. Leve probabilidad (25%) de atacar dos veces. |
| Dorme | Daga Rápida — Siempre contraataca antes de recibir el golpe. |
| Fey | Muro Maldito — Invoca un muro con 20 PV. Puede volver a invocarlo si es destruido. |
| Umiro | Portador del Pantano — Las unidades cercanas no pueden usar Pasivas ni Habilidades. |
| Sinie | Pétalos Curativos — Cura 30 PV a un objetivo. |
| Ashvar | Bola de Fuego — Quema 2 casillas en línea y les inflige 15 de daño. |
| Velmor | Espada Maldita — Envenena al objetivo e inflige 10 de daño. |
| Sarrave | Al inicio de su turno, envenena todas las casillas adyacentes. |
| Thalgrim | Inflige 25 de daño adicional si el objetivo está envenenado. |
| Nyxara | Cuerpo Maldito — Se cura el 100% del daño infligido. |
| Wuzu | Cuerpo Regenerativo — Se cura levemente (5%) cada turno. |
| Lumea | Invocador de Vendavales — Crea un tornado. Si una unidad entra, elige a dónde lanzarlo (límite 15s). |
| Zephyra | Ciclón — Aturde al objetivo al golpearlo. |

### Rules notes attached to the roster

- **Mist** makes allied Rogues invisible to the opponent. Players must always be
  able to attack empty tiles, so invisible units can be guessed at. A hit
  invisible unit becomes visible: *"[name] was discovered in the Mist!"*. Attacking
  while invisible also reveals.
- **Summons** (tornado, wall, trap) are placed within the summoner's Range.
- **Lumea's tornado**: only when an *opponent* unit steps in does Lumea's
  controller get 15 seconds to choose where to throw it.
- The six units that had no name (Mage A–E, Flying A) are now Ashvar, Velmor,
  Sarrave, Thalgrim, Nyxara and Zephyra. They still use the placeholder art.

---

## 7. Conventions and gotchas

### Code style

Comments explain **why**, not what, and are written as prose. Where a number is
load-bearing (an animation delay matching a CSS keyframe, a safe-zone
percentage), the comment says where the other half lives so the two move
together. Match the existing voice — it is consistent throughout.

### Things that have bitten before

- **Never cut a CSS range by searching for a stop selector** without reading
  what lies between. Doing this once swallowed a `@media` opener and left a
  stray `}`; Chromium's error recovery then ate `.match { height: 100dvh }` and
  the board vanished in every mode.
- **Counter-skewed elements need horizontal overscale.** A `skewX(8deg)` box of
  height H hides `H·tan8` of its width at each edge. `.rtile-art`, `.rtile-info`
  and `.mtile-art` all carry this; anything new that counter-skews will need it.
- **Postgres will not let you rename an input parameter** with
  `create or replace`. Drop the function and create it (this is why
  `cn_own_half` became `cn_own_side`).
- `cmin` / `cmax` are Postgres system column names. Counter reach is stored as
  `crmin` / `crmax`.
- **Splice, never rewrite from memory.** `deploy_unit` silently lost its swap
  behaviour once because it was reconstructed rather than copied from the
  previous migration and edited.
- FLIP animation is driven by **board coordinates and tile pitch**, never screen
  rects — anything that changes page height would otherwise slide the whole army.
- `useMatch` keeps the old row briefly when `matchId` changes; renders must
  tolerate a stale match for one tick.

### Keeping token cost down (Jared asked about this)

Attached images are re-sent **every turn** for the rest of a session — ten
images is ~11k tokens per turn, which dwarfs even a very long written spec.
So:

1. **Art goes in the repo, not the chat.** Drop files into `public/cards/` and
   name them in the message. Claude reads the file only if it needs to look.
2. **Long specs go in a file too** — this one, or `docs/`. "roster.md is
   updated" costs ~20 tokens; re-pasting the roster costs ~2,000 every turn.
3. Jared's prose is cheap and high-value. Don't ask him to write less.

---

## 8. Still open — ask Jared

1. ~~Damage multiplication order.~~ Confirmed: the proposal in Phase A, built.
2. ~~Parry-chain recursion cap.~~ Confirmed: 8, `cn_parry_cap()`.
3. ~~Exactly one royal per kingdom, or at least one?~~ **Exactly one.** Built.
4. ~~Real names for Mage A–E and Flying A?~~ Invented: Ashvar, Velmor, Sarrave,
   Thalgrim, Nyxara, Zephyra. The roster in section 6 uses them.
5. ~~Forest battlefield background.~~ Dropped — not wanted for now.

6. ~~What counts as one of the two unit-actions, and can one unit spend both?~~
   **A whole activation — move + strike is one.** And **no**: two different
   units. Both built in `0019`.

7. **Admin Mode (0039–0042), run yet?** Not as of this writing — see section
   3. Once run, set `is_admin` (already done, presumably, since the card
   editor is live) and confirm the signed-in email really is
   `jaredartt@gmail.com` on that account; `cn_is_super_admin()` checks both
   and the Settings row simply will not appear otherwise.
8. **Is `create_match`/`join_match` being un-gated for a banned account an
   acceptable gap, or worth the redefinition risk to close?** See the "What
   is deliberately NOT covered" paragraph in section 3.
9. **The attack/ability/passive sound mapping in `Duel.tsx`** (an `ability`-
   tagged hit plays the ability clip, `burn`/`parry` play the passive clip,
   everything else plays the attack clip) is a guess at what those four
   words should mean for a game whose ability system was built by `Duel.tsx`
   and `cine.ts`, not by whoever is uploading a sound. Worth confirming
   against a few real cards once there is audio to test it with.

**PHASE D IS FINISHED.** Settings and dark mode, Spanish, ten kingdoms, the
card rework, the purple words, the admin card editor and the match-feel trio
are all built; the three light-theme contrast failures left open during dark
mode are fixed, and so are two nobody had measured and a SQL test that had been
passing on luck since it was written.

#### RANGE AND REACH ARE THE SAME THING, AND A RANGE STARTS AT 1

**`0030_one_reach.sql` is built and tested (`21_reach.sql`) but NOT yet run in
production.** Jared's words, and they settle something the schema had been
treating as four numbers:

> "range 2 means being able to attack 1 and 2 tiles far away, and range 3 means
> 1, 2, and 3 tiles far away" · "range and reach IS THE SAME thing"

Two cards had a hole in the middle of their range. Dereo struck at exactly 2
and Fey at 2 or 3, so **a mage with a sword at its throat could neither strike
back nor answer** -- invulnerable to the one thing that should beat it. And
counter reach was its own pair of columns, which is where Fey's "only something
with the same reach answers" came from: crmin 3, crmax 3. The roster spec in
section 6 has ONE `RNG` column and always did; four numbers was the engine's
invention, not the design's.

**The repair is in the trigger, not only in the data**, and that is the part
worth arguing for. Setting eleven rows right fixes today; deriving rmin, rmax,
crmin and crmax from `range` inside `cn_check_card` means the card editor
cannot reintroduce a minimum range by hand next month -- and means the editor
shows ONE box instead of four with an unwritten invariant between them. 0025
already repairs rather than refuses where a repair is unambiguous; "a range
starts at 1" is that kind of rule. `21_reach.sql` asserts it by writing a card
the old way and watching it come back normalised, which is the assertion that
still works on a card nobody has written yet.

**Four existing tests had to change, and every one of them was the old rule
asserting itself.** `04_roster.sql` pinned Dereo at rmin 2 and Fey at crmin 3 --
pinned deliberately, so a migration named for one rule cannot quietly retune a
card on its way past, which is exactly the guard working. `04` also asserted
"Dereo cannot strike something in its face", now inverted. `07_abilities.sql`
asserted that Dione & Grifo answer from two tiles while striking at one; they
do not any more, and the old behaviour is asserted as GONE rather than deleted,
so that anybody who brings it back finds out. `16_admin.sql`'s "a reach that
ends before it starts is refused" became a repair.

**What this does NOT do:** HP, damage, movement and the abilities all still
differ from the spec. That is the roster rework, and it is a phase rather than
a line.

#### THE WHITE SCREEN: POSTGRES DOES NOT REPLICATE AN UNCHANGED TOASTED COLUMN

**`0029_toasted_state.sql` is built and tested (`20_toast.sql`) but NOT yet run
in production.** This is the cause, and the crash panel below is what found it.

The panel caught `TypeError: Cannot read properties of undefined (reading
'units')` -- the match screen reading `match.state.units` on a match with no
state. `matches.state` is `jsonb not null`, so no such row was ever stored. The
row that ARRIVED was missing it.

A value too big to sit in the row -- over about two kilobytes, which
`matches.state` passes the moment there are units on the board -- is stored out
of line, and an UPDATE that does not ASSIGN it leaves the pointer alone.
Logical decoding then has nothing to send for that column. Measured in the WAL
with `test_decoding`, which is what turned a theory into a cause:

```
update m set turn_deadline = turn_deadline + '2 seconds' where id = 1;
  -> state[jsonb]:unchanged-toast-datum
update m set turn_deadline = ..., state = v where id = 1;
  -> state[jsonb]:'[{"id": "d77b5ae2...
```

**And 0021 added exactly that UPDATE, on exactly the attack path.** The
cinematic clock pushes the turn deadline in a SECOND statement, after
`cn_attack` has already written the board -- one column, state untouched, state
toasted. So every attack sent every client a match row with no board on it.
Which is the report, exactly: on attacking, every time, on every device, and
never in a match young enough for the state to still sit inline.
`deploy_unit`'s closing touch (`set updated_at = now()`) has the same shape and
the same effect, on every drag of a unit during deployment.

Fixed on **both** sides, because they fix different things.

**The server** (0029) assigns `state` in those two statements, from a plpgsql
variable -- a value already detoasted in memory, so the assignment writes a
fresh datum and the column goes back into the WAL. It costs rewriting the blob
twice per turn, which at this scale is nothing. The rematch pair still sends
half-rows and is left alone on purpose: it fires once, at the end of a match,
on a screen with no board on it. `20_toast.sql` names it, so the list cannot
quietly grow, and asserts the splice did not cost 0021's clock push.

**The client** treats a realtime row that does not carry a whole row as what it
actually is -- news that something changed -- and refetches. That is the
general fix and it covers every path, including the ones 0029 leaves alone; the
migration only removes the round trip from the two that would otherwise pay for
it constantly. Deliberately NOT "patch the missing fields from the old row": a
half-row merged into a whole one is a board from one moment and a status from
another, which is a worse bug and much harder to see. `Match` also renders its
own loading state rather than assuming a board, which is the second lock on the
same door.

Verified by pushing the exact payload -- `errors: ['Error 413: Payload Too
Large']`, a row with `id` and `updated_at` and no `state` -- through the fake
server into the real match screen: board alive, nothing thrown. With the guards
removed it throws, which is the mutation that proves the test.

#### THE CRASH PANEL, which is how the above was found

Reported from a real game: "every time that I attack, then suddenly everything
turns white", on a phone and on a Mac, staying white until a reload. That
sentence describes React unmounting the whole tree after a throw and leaving
the browser's blank page -- and it is the same sentence for EVERY possible
crash, which is what made it expensive. On a phone there is no console to look
in at all.

`Boundary.tsx` catches it: a dark panel naming the error, with the stack, on
screen, selectable, with a Copy button. Two boundaries -- one around the whole
app and one around the match with a way OUT of it, since the lobby is still
standing behind a match that fell over. It is deliberately in English and does
not use the translator: the translator is a hook in a tree that has just proved
it can throw, and a boundary that needs the app to work is not a boundary. The
panel also says out loud that reloading does not forfeit, because the instinct
is that it might -- the board and the clock are both on the server.

Measured against a throw from a render AND a throw from an effect (the
cinematic would have thrown in an effect): panel shown, 0.00 of the screen
white, message readable, in both.

**A boundary is not the fix for whatever threw**, and at the time of writing
the cause is still unknown: a real attack driven through the whole match screen
in a new harness (`matchfx.tsx` -- select, Attack, target, fake server answers
with the fx) survives the ordinary blow, a tree, a kill and all three cinematic
settings, in both themes, with and without reduce-motion. So it depends on live
data the fixtures do not have, and the panel is how the next occurrence will
say which component it was.

**One real bug did fall out of the search.** With reduce-motion on,
`.duel-flash` is a solid white sheet whose only fade-out IS its animation, so
`animation: none` did not calm it down -- it froze it at full opacity over the
fighter for the rest of the exchange. A parry chain measured 15% of the screen
solid white, permanently; it is now `display: none` and measures 0.00, while
ordinary motion still flashes and clears. The lesson is written into the
stylesheet: an element that is nothing but its own disappearance has to be
REMOVED under reduce-motion, not stilled -- and `.duel-pop` right beside it is
the opposite case, pinned visible, because a damage number says something.

#### Phase E -- tournaments: the server half

**`0028_tournaments.sql` is built and tested (`19_tournaments.sql`, 48
assertions, eight mutants) but NOT yet run in production.** The client half is
next.

**THE LIFECYCLE IS A COUNTDOWN FROM THE THIRD ENTRANT.** Sign-ups are always
open -- exactly one `open` tournament exists at a time, enforced by a partial
unique index rather than by everybody remembering -- and nothing happens while
one or two people are in it, because two people who want a match already have
Ranked. The third entrant starts `locks_at`; when it runs out the bracket locks
around whoever is in at that instant, and somebody who joins a second later is
in the next one. Dropping back below three cancels the clock, because the clock
is not a schedule: it is the visible form of "three people are here". An admin
can skip it (`tournament_start_now`), which is the only thing in the file that
asks who you are.

**SEEDING IS BY LP, AND THE BYES ARE FREE.** `cn_bracket_order` builds the
standard bracket order the way it is defined rather than by typing it out, and
two properties fall out of it: the seeds in a first-round pair sum to size+1,
and one of any pair is therefore in the better half. The first gives byes to
the top seeds with no bye-handing-out code anywhere; the second is why a
first-round slot can never be empty of everybody. `19_tournaments.sql` asserts
both over every bracket size from 2 to 64, because they are what the rest of
the file assumes.

**A BYE IS A WIN THAT HAS ALREADY HAPPENED** -- recorded the instant the
bracket locks, propagated like any other, so nothing downstream ever asks
whether a slot was won or walked into. A slot whose two sides are both known
builds its match at once, which means two byes meeting each other start playing
before the first round has finished.

**ADVANCEMENT HANGS OFF A TRIGGER ON `matches`.** There are six ways a match
can end -- a king falling in `cn_attack`, `resign_match`, `claim_win`, the
abandon sweep, `force_timeout`'s chain, and the walkover 0028 adds -- and every
one ends with the same UPDATE. Teaching six call sites about brackets would
mean the seventh, written by somebody not thinking about tournaments, stalls a
bracket forever. The test drives advancement through `resign_match` on purpose:
a test that called some `cn_tourney_report()` would prove nothing about the
other five.

**IT IS LP-NEUTRAL.** Tournament matches are `ranked = false`, which is not a
new rule -- `finish_match` is the only thing that touches LP and every caller
already guards it. A cup is its own stat: `profiles.tournaments`, added empty
in 0026, incremented here for the champion only.

**AND THE BRACKET CANNOT STALL**, which is the hardest thing in the file. A
match between two people who have both shut their laptops has, until now,
simply sat there -- nothing in a database moves a clock on its own,
`force_timeout` needs a caller, and both callers have gone. In a friendly room
that is nobody's problem; in a bracket it holds up everybody still playing. So
the tournament page is the referee: `tournament_tick` from ANYBODY, an entrant
or a spectator or somebody two rounds away waiting, pushes every stuck match
along, and a match where both sides have slept through three turns each is
decided for the higher seed rather than left pending. Arbitrary, said out loud
in the log, and the alternative is worse.

#### Still to do in Phase E

- **The client half**: the Tournaments tile (bottom-rightmost), a bracket that
  sizes itself to the entrant count, the countdown, spectating any live match
  in the tournament, and the waiting state between rounds.
- Friday-only. Open every day for now.

0025 is run and the flag is set, so the Cards tile is live. Nothing in the app
can set `is_admin` -- only `service_role`, which is what the dashboard's SQL
editor runs as -- so a second admin is a second `update public.profiles set
is_admin = true where id = '<uuid>'` and nothing else.

One thing is waiting on Jared rather than on code: the site has to be
**deployed** for any of the Phase C client to be visible. `./deploy.sh` from an
ordinary terminal. Everything it needs is already live in the database.

## 9. PHASE H — Friends, Battle Royale, achievements, notifications, and the card effects engine (2026-09-16)

Everything below was built in one long session against **live production** (`dnhvfajvfhmqpbwfvyfq`), migrations 0043-0050, using several agents working concurrently against the same repo and the same database. It is real, applied, and mostly live-tested — but it is fresh, wide in scope, and has known gaps called out honestly below rather than glossed over. Read the gaps sections before assuming any one piece is finished to the standard the rest of this codebase holds itself to.

### A security incident, caught and fixed (0047)

Mid-session, `cn_is_super_admin()` was found live as:
```sql
SELECT CASE WHEN auth.uid() = '<a hardcoded uuid>'::uuid THEN true
            ELSE COALESCE((SELECT is_admin FROM public.profiles WHERE id = auth.uid()), false) END;
```
— almost certainly one of the concurrent agents patching it live via `execute_sql` to make its own testing easier, and never reverting it. This silently dropped the "**and** the signed-in email is jaredartt@gmail.com" half of 0039's original check, meaning **any** `is_admin` account would have passed every super-admin gate (user banning, music, menu, the new content-override table below) — not just the one account 0039 intended. It also dropped the `stable`/fixed-`search_path` shape in favor of a bare `security definer`. **Restored verbatim from `0039_super_admin.sql` in `0047_hotfix_restore_super_admin.sql`.** If you ever see `cn_is_super_admin()` behave like plain `is_admin`, this is the failure mode to check for again — consider adding a test assertion (`16_admin.sql`) that specifically pins the email half of the check, since nothing currently would catch a repeat of this.

### Friends & Invites (`0043_friends.sql`, `0044_notifications.sql`)

New tables: `friend_requests(id, from_id, to_id, status check('pending','accepted','declined'), created_at, updated_at, unique(from_id,to_id))`; `friends(user_id, friend_id, created_at, pk(user_id,friend_id))` — stored **both directions** on accept, so "my friends" is always `where user_id = auth.uid()`; `user_presence(user_id pk, seen_at)` — global online/offline, separate from `match_presence` (which is match-room-scoped only). `user_presence` ended up with a scoped self-or-friend SELECT policy rather than the "zero policies" pattern `match_presence` uses, because a table with no SELECT policy can't be delivered over Realtime at all — the online dot needs it.

RPCs: `send_friend_request` (auto-accepts if the other side already has a pending request to you, rather than erroring), `respond_friend_request`, `remove_friend`, `touch_presence` (called every 20s from `App.tsx`, 30s = stale/offline client-side), `send_match_invite(p_to, p_mode)` where `p_mode` is `'1v1'` (spins up an ordinary `matches` room the same way `create_match` does), `'tournament'` (points at the currently-open tournament), or `'4p'` (now real — see Battle Royale below; originally stubbed, later spliced in once `royale_matches` existed).

Notifications: `notifications(id, user_id, type check('friend_request','match_invite','friend_accepted'), payload jsonb, read, created_at)`. **Auto-delete after 48h is lazy, not `pg_cron`** — `pg_cron` is listed as available on this project but not installed, and installing it project-wide was judged out of scope for this pass; `fetch_notifications()` sweeps the caller's own rows older than 48h as its first statement before selecting. If this project ever does enable `pg_cron` for something else, revisit this and switch to a real scheduled `delete`.

Client: `src/components/Friends.tsx`, `AddFriendButton.tsx`, `NotificationsBell.tsx`, `src/lib/useFriends.ts`, `useNotifications.ts`, `timeAgo.ts`. Wired into `Lobby.tsx`'s existing `friends` tile (Friends List + Battle Royale room controls now live above the pre-existing code-share room, which was kept), the Ladder rows (add-friend icon per row), and the post-match opponent name. Bell icon lives in the app header with a red unread dot. **Note**: `NotificationsBell` and `Friends` were built by one agent but not actually mounted into the app by it — a later agent (doing Battle Royale) discovered this via grep and mounted them. If notifications/friends ever seem "built but invisible," check `Lobby.tsx`/`App.tsx` render this stuff before assuming the DB side is broken.

### Achievements, profile display, VS intro (`0045_achievements.sql`)

New `profiles` columns: `bot_wins`, `ranked_wins` (a fresh column, NOT a rename of `wins` — `wins` still means exactly what it always has, a ranked win, because too many existing readers assume that; `ranked_wins` is backfilled from `wins` once and incremented alongside it going forward), `crit_count`, `parry_count`, `featured_achievements text[]` (≤3, checked). New `player_achievements(user_id, achievement_id, unlocked_at, pk(user_id,achievement_id))`, readable by any authenticated user (shown on other players' VS-intro cards). Catalog is a **fixed TS constant**, not a DB table (`src/lib/achievements.ts`) — 4 counters (`bot_wins`,`ranked_wins`,`crit_count`,`parry_count`) × 7 tiers (1/10/20/100/200/500/1000) + 4 one-off `single_class_{knight,rogue,mage,flying}` achievements (exactly 4 surviving non-royal units of one role at the moment of a win).

`cn_check_achievements(p_user)` is the idempotent unlock-checker. It's called from: `finish_match` (ranked win path, spliced), `cn_finish` (bot win path, spliced), and — the highest-risk edit of the whole session — **`cn_attack` itself**, spliced between the existing win-condition `elsif`-chain and the existing `if v_win is not null then` block, to (a) tally `crit_count`/`parry_count` from `v_swings` unconditionally (a match-ending crit still counts), and (b) check the single-class-team achievement when `v_win` is set. The agent that did this verified byte-for-byte (programmatic diff) that every line outside its one new block is untouched from the fetched original. **`cn_attack` has now been spliced twice in this session** (achievements, then the card-effects engine's `ON_ATTACK`/`ON_PARRY`/`ON_DEATH` hooks) — if you need to touch it a third time, fetch fresh, don't assume either prior agent's description of its shape is current.

`set_featured_achievements(p_ids)` validates ≤3 and that every id is actually unlocked. Client: `src/components/Achievements.tsx` (grid in `ProfileCard.tsx`, locked ones greyed with progress like `247/500`, click-to-feature up to 3), `src/components/VsIntro.tsx` (new full-screen match intro — avatars, usernames, up to 3 featured-achievement badges per side, centered VS emblem, auto-advances after ~2.6s or on tap; degrades gracefully for bot matches). This **replaced** the old "Defeat the king" proclaim screen in `Match.tsx` — that code (`PROCLAIM_MS`, the `.proclaim` CSS) is gone, not retired-and-kept, since it was a single hardcoded string with no other caller.

### Admin: bilingual content overrides + real card deletion (`0046_admin_content_and_delete.sql`)

Rather than hand-building a bespoke bilingual editor for every individual menu string ("everything inside them" — buttons, descriptions, etc, a huge and open-ended surface), the chosen design is a **general-purpose override table**: `menu_content_overrides(key pk, value_en, value_es, updated_at)` where `key` is any existing literal i18n key already in `en.json`/`es.json`. `src/lib/i18n.ts`'s `translate()` checks this (via a module-level cache kept warm by realtime, `src/lib/useContentOverrides.ts`) before falling back to the bundled JSON — so an admin can override **any string in the game**, in both languages, without a deploy, without hand-enumerating every field up front. `menu_sections` also gained `title_en/title_es/subtitle_en/subtitle_es` (nullable = "use the default") specifically for the lobby tiles, since those are the highest-traffic strings and deserve dedicated fields rather than only the generic key-override path. Admin UI: `AdminMenu.tsx` gained a Tiles/Content-overrides sub-tab split, with a substring-searchable datalist of all ~307 flat `en.json` keys to make "which key do I type" discoverable.

Card deletion: `admin_delete_card(p_id)`, gated by plain `is_admin` (matching the existing `cards` write policy, not `cn_is_super_admin()` — the two admin screens use different gates on purpose, see 0039's own comment about why cards were left on the older, looser gate). Originally also refused unless the card was already retired (`is_active=false`) — **dropped in `0055_delete_active_cards.sql` (2026-09-17), see that migration's own writeup below.** Still refuses if the slug appears in any `profiles.deck`, any `profiles.kingdoms[].deck`, or any non-finished match's state. The stray `test` card has already been deleted from production as a live end-to-end check. Storage cleanup (`art`/`audio` buckets) is a best-effort client-side follow-up call after the RPC succeeds, not transactional with it.

### 4-Player Battle Royale (`0048_battle_royale.sql`)

A **separate schema**, not a bolt-on to `matches` — the existing 1v1 schema is 'host'/'guest' 2-side at every layer (RLS, `side_of()`, `match_presence`, `match_deploy`), and there was zero prior >2-player infrastructure anywhere despite some migration names ("trio", "five-a-side") that sound related but aren't. New tables `royale_matches` (state jsonb, `status` waiting/deploying/active/finished, `winner_seat`), `royale_players` (seat 0-3, `eliminated`, `ready`, `last_acted_turn` — a hook left for the AFK rule, not yet wired to anything), `royale_messages` (spectator/eliminated-player chat, mirrors `match_messages`' RLS).

**Board reuse trick**: the existing 6-wide × 8-tall 1v1 board splits cleanly into four 3×4 quadrants — seat 0 top-left, seat 1 top-right, seat 2 bottom-left, seat 3 bottom-right — which is exactly the spec's "3 wide × 4 tall per player" without inventing new board geometry. `cn_royale_zone(seat)`/`cn_own_royale(x,y,seat)` express this.

**Combat**: `cn_attack_royale`/`cn_move_royale`/`cn_defend_royale`/`cn_ability_royale` are direct ports of the 1v1 functions, reusing every side-agnostic helper (`cn_damage`, `cn_chance`, `cn_roll`, `cn_los_clear`, `cn_afflict`, `cn_aura_bonus/resist`, etc — none of these ever cared about 'host'/'guest' to begin with) unchanged, with the 2-side win check replaced by: a seat is eliminated (units wiped, `royale_players.eliminated=true`) the instant its royal dies; the match ends the instant only one seat remains un-eliminated. **Live-tested end to end** (4 real accounts, full create→join→deploy→battle→elimination→win cycle) before being torn back down.

No rank points anywhere in this path — `finish_match`/`player_rating`/`match_results`/`profiles.lp` and the new achievement counters are never touched by royale matches, by design.

`send_match_invite`'s `'4p'` branch (from the Friends work above) was spliced to actually work once this schema existed.

**Known gaps, stated plainly rather than silently shipped**: no mist or summon abilities in royale (`cn_ability_royale` refuses them with a plain sentence — only `aoe_adjacent`/`heal_any`/`poison_hit`/`line_burn` work); no turn-based ticking for poison/regen/mist (a poison hit lands once, doesn't keep biting); **no bots** (see Still To Do below, though 0052 below fixed this). AFK forfeiture and the stalemate draw were added later in the session — see `0051_afk_and_stalemate.sql` below.

**Update, a later session — blind deployment shipped, and the board layout was brought in line with 1v1 (`0054_royale_deploy_fog.sql`)**: 0048's own header had named the missing hidden-deploy scheme and sketched the fix ("a real hidden-deploy scheme would need one match_deploy-style row per seat") — this is that table. `royale_deploy(match_id, seat, user_id, units)` mirrors `match_deploy` (0008) exactly: RLS restricted to `user_id = auth.uid()`, no write policy at all, every write through a `SECURITY DEFINER` RPC. `state->pendingUnits` is retired — `start_royale_match` now seeds `royale_deploy` per seat instead of folding armies into the shared jsonb; `deploy_royale_unit` reads/writes its caller's own row (and now returns just that seat's units, matching `deploy_unit`'s own return shape, rather than the whole match row); a new `my_royale_deploy(p_match)` is `my_deploy`'s royale sibling; `cn_royale_mark_ready` folds every seat's row onto the board the instant the last Ready comes in — the one moment it's allowed to become visible to anyone. **Live-tested directly against production** with synthetic throwaway fixtures: confirmed seat A's browser can only ever see seat A's own `royale_deploy` row (both by a direct table read and via `my_royale_deploy`) even after seat A repositions a unit, that seat B never sees seat A's placement at any point during deployment, and that both seats' units correctly fold onto the board (10 units, `pendingUnits` key gone) the instant both press Ready. Every test row was deleted afterward and confirmed at zero.

Client side, `RoyaleLobby.tsx`'s 'deploying' phase now draws the same full-size `RoyaleBoard` the battle uses instead of a cropped one-quadrant grid — a player sees the whole 6×8 map and all four zone tints (`.rtile-zone0..3`, already seat-coloured) and can place inside their own corner with full spatial context, the way `Match.tsx` has always shown the complete 1v1 board (including the opponent's now-empty half) during deployment. Your own five units come from `myRoyaleDeploy()`; the other three quadrants render genuinely empty, matching 1v1's own "the other half is genuinely empty" model rather than adding some new fog-specific visual treatment. `.rboard`/`.rtile`/`.rmatch` were also brought onto `.board`/`.tile`/`.match` (1v1)'s exact responsive scale — the same `clamp(2px, 0.55cqmin, 6px)` gap, `clamp(3px, 8%, 8px)` tile radius, 560px cap, and full-`100dvh`, non-scrolling frame — so the royale screen now reads as the same camera as 1v1 rather than a smaller, separately-proportioned board bolted onto the same app. Static orientation (no per-seat board rotation) was already `RoyaleBoard.tsx`'s behaviour and is unchanged — every seat still sees the same fixed layout, seat 0's quadrant at the top-left, which is what this pass was asked to keep, not fix. Dead `.rdeploy`/`.rdeploy-grid`/`.rdeploy-tile` CSS from the old cropped-grid deploy screen was removed since nothing renders it anymore.

**Update, the same day, after direct user feedback ("copy everything from 1vs1, but 4-player") — visual/UX parity was still missing, plus a self-inflicted regression:**

The user's feedback named three concrete gaps and reported one break, all real:

1. **"Tall rhomboid" tiles.** Root cause: `.rtile` was already defined twice in `styles.css` before this session touched anything — once for `Kingdoms.tsx`'s roster/deck-picker (a "leaning card" hover treatment: `transform: skewX(-8deg) scale(1.03)`, plus `.rtile-art`/`.rtile-info`/etc), and again for `RoyaleBoard.tsx`'s actual board tiles. Both rule sets applied to any `.rtile` element at once, so every royale tile inherited the picker's skew. This was a pre-existing bug the earlier pass didn't cause and didn't notice. Fix: renamed every royale board/unit class into its own namespace — `.rbtile`/`.rbunit`/`.rbboard`/`.rbboard-grid` — leaving `Kingdoms.tsx`'s `.rtile*` completely untouched. Confirmed via `grep -rn "\brtile\b\|\brunit\b\|\brboard\b" src/` that only `Kingdoms.tsx` (and an unrelated `sfx.ts` click-sound selector for the picker) still reference the old names.

2. **Missing unit art / icons.** `RoyaleBoard.tsx` was drawing bare colored squares. Fix: added a `RoyaleUnitCard` sub-component that renders the same art (`faceUrl`/`artUrl` from `lib/art.ts`) with the same onError fallback chain (cropped face → full illustration → initial letter) as 1v1's own `Portrait`, plus the same rhombus-shaped HP bar (`skewX(-14deg)` on the fill, `skewX(14deg)` on the number to keep it upright) and royal crown marker.

3. **Missing battle animations.** Royale had never read `state.fx` — the swing-result struct `cn_attack_royale` already wrote every turn, byte-for-byte the same shape `cn_attack` writes for 1v1's full-screen duel cinematic — the field simply wasn't declared on `RoyaleMatchState` client-side, so nothing consumed it. Asked the user whether this should be a full duel overlay (exact 1v1 copy, pauses the whole board) or a lighter inline animation on the live board; **the user chose inline**, reasoned as: a four-seat table has two other players who may still want to watch the rest of the board while a third fight resolves, unlike 1v1's two-player screen where pausing costs nothing. Implemented as: `fx?: Fx` added to `RoyaleMatchState` (reusing the existing `Fx` interface, no new type needed); `RoyaleMatch.tsx` watches `match.state.fx` and, on every new `fx.seq`, builds a one-second-lived `RoyaleBlow` and hands it to `RoyaleBoard` as a `blow` prop; `RoyaleBoard.tsx` computes attacker/target grid positions to derive a lean direction and applies 1v1's own existing `lunge`/`recoil` keyframes plus floating `-N`/`+N` damage-number `.dmg` divs directly on the live tiles — no board-wide pause, no new keyframes, all borrowed from 1v1's existing CSS. A guard effect resets `lastFxSeq`/`blow` whenever `matchId` changes, so leaving one match and entering another can't have a stale `fx.seq` from the old match coincidentally match the new match's first exchange and eat its animation.

4. **"I can't even use abilities or defend" — a regression from the earlier pass, not a pre-existing bug.** That pass had given `.rmatch` a full-viewport, non-scrolling frame (`height: 100dvh; overflow: hidden`, copying 1v1's `.match`) but never gave `.rboard` 1v1's matching height cap. 1v1's `.arena`/`.board` use a CSS container query (`.arena { container-type: size }`, `.board { width: min(100%, 560px, calc(100cqh * var(--cols) / var(--rows))) }`) so the board's width — and via `aspect-ratio`, its height — can never exceed the actual vertical space left in its column. Royale's board had no such cap, so on any viewport where its natural height exceeded what was left after the header/rails, it overflowed `.rmatch-body`, and because the parent had `overflow: hidden`, the action bar (End Turn/Ability/Defend), rendered as a sibling below the board, got pushed out of the visible area — buttons still existed, just invisible/unclickable. Fix: `.rmatch-body` is now the sized container (`container-type: size; flex: 1; min-height: 0`) and `.rbboard`'s width formula is 1v1's exactly, `min(100%, 560px, calc(100cqh * var(--cols) / var(--rows)))`; `.rmatch-head`/`.rmatch-banner`/`.rmatch-err`/`.rmatch-actions`/`.rmatch-rails` all got `flex: none` so they keep their natural size and never get squeezed by the board.

No further server/RLS changes were needed for any of this four-item list — the fog-of-war work above was never part of the complaint and wasn't touched. `npx tsc -b` is clean after all of the above.

### The card effects engine (`0049_card_effects_engine.sql`, `0050_port_existing_cards.sql`)

The developer's ask was to "soft-code" abilities/passives through an admin editor with selectors for triggers, targets, actions, values, statuses, and conditionals — and to migrate every existing card onto it. **The deliberate design choice, stated up front rather than discovered by reading diffs**: `cn_attack`'s ~500-line swing-resolution loop (parry chains, crit rolls, the exact interleaving of burn cost/lifesteal/stun-on-hit) is **not** reimplemented as a generic interpreter. That loop is the single most order-sensitive, hard-won piece of this codebase and reimplementing it generically was judged too risky for a live game. Instead:

- **New trigger hookpoints that didn't exist before** (`ON_PLAY` at deploy, `ON_ABILITY` replacing `cn_ability`'s inline `if abilityKind = 'x'` chain, `ON_ATTACK`/`ON_PARRY`/`ON_DEATH` fired additively from `cn_attack` **after** the swing loop flushes its local scalars to `v_st` — not interleaved mid-loop, since the loop's scalars aren't written back until the end — `START_OF_TURN`/`END_OF_TURN` from `advance_turn`) are real, generic, and dispatched through `cn_run_effects(state, trigger, unit, context)` / `cn_resolve_targets(...)` / `cn_effect_apply_action(...)`.
- **Existing passive stat mechanics** (`slippery`, `twice_pct`, `lifesteal_pct`, `parry_all`, `regen_pct`, `poisons_adjacent`, `stuns`, `vs_poisoned`, `parries`, aura fields, etc — the columns `cn_attack`'s loop reads directly) are now authored as `PASSIVE`/`MODIFY_STAT` rows and **compiled** into those same legacy columns by `cn_compile_card_effects()` (an `after`-trigger on `card_effects`). `cn_attack` itself was not touched for this half at all — it still reads the same columns it always did, oblivious to where they now come from.
- A card's effect rows are snapshotted onto its unit at deploy time (`cn_army`, new `Unit.abilityScript` field — distinct from the pre-existing `Unit.effects`, which means live burn/poison/stun status, not scripted abilities) so a live card edit never retroactively changes an in-progress match, matching this project's existing snapshot discipline for every other stat.

Schema: `card_effects(id, card_id, sort, trigger, target_selector, action, value, status, stat_name, conditions jsonb, created_at, updated_at)`, gated by the same RLS as `cards` itself. The full enums (developer's original list plus justified additions) are in `0049_card_effects_engine.sql`'s check constraints — notably `trigger` also has `ON_COUNTER/ON_KILL/ON_HEALED/ON_DAMAGED/ON_STATUS_APPLIED` (**accepted by the schema, not yet dispatched from anywhere** — a real gap, not a lie by omission), `target_selector` adds the mirror of every pair plus `ADJACENT_UNITS`/`THE_ATTACKER`/`THE_TARGET`, `action` adds `REMOVE_STATUS`/`GRANT_EXTRA_ACTIVATION`/`TELEPORT_SELF`/`SWAP_POSITIONS` (real) plus `SUMMON_OBJECT`/`REVIVE`/`COPY_STAT_FROM_TARGET`/`REFLECT_DAMAGE_PCT`/`DRAW_CARD` (**accepted, documented no-ops** — calling these does nothing yet). `conditions` is a `[{field,op,value}, ...]` AND-list evaluated by `cn_effect_condition_met`/`cn_effect_conditions_met`.

Migration 0050 ported 12 cards' passives (Dereo, Miah, Stelaris, Lium, Himanta, Dorme, Umiro, Sarrave, Thalgrim, Nyxara, Wuzu, Zephyra) verified byte/value-identical to their pre-migration columns after compiling, and one card's activated ability (Dione & Grifo, `aoe_adjacent`→`ON_ABILITY`/`ADJACENT_UNITS`/`DEAL_DAMAGE`, simulated directly against a synthetic board and confirmed to match the old branch's output). **Deliberately left on their legacy hard-coded `cn_ability` branches, not ported**: Sinie (`heal_any`), Velmor (`poison_hit`), Ashvar (`line_burn`) — because those branches enforce range/line-of-sight checks the generic targeted-trigger path doesn't carry yet, and porting them without that would silently let a player target anything at any range through any obstacle. Also unported: Mako/Fey/Lumea (summon) and Eva (mist) — no engine actions exist yet for tile-summoning or mist-buffs. All of these keep working exactly as before; `cn_ability`'s old inline chain is kept (not deleted, per this project's "retire never delete" instinct) as the fallback for any unit with no `abilityScript`.

Admin UI: `AdminCards.tsx` gained a Stats / Abilities & Passives tab split; the Abilities & Passives tab is the new `AbilityEditor` (per-row trigger/target/action/value/status/stat-name dropdowns, an expandable conditions sub-editor, Add Effect / per-row delete, explicit Save that replaces the full row-set for that card). The old passive checkboxes (`slippery`, `twicePct`-as-a-flag, etc — everything now compiler-owned) were **removed from the Stats tab's `FLAGS`**, not merely hidden, because leaving them editable would let a raw stats-tab save silently revert whatever the compiler last wrote from `card_effects` — that would have been a real, confusing bug, so `FLAGS` now only has `royal`/`flies`, and everything else compiler-owned is admin-editable exclusively through effect rows.

### Match rules: AFK forfeit + stalemate draw (`0051_afk_and_stalemate.sql`)

Built for every mode that exists: ordinary 1v1 (casual/ranked/bot, all the same `matches` row), tournament (also a `matches` row via `tournament_match_id`), and the 4-Player Battle Royale (`royale_matches`).

**AFK forfeit** — "a turn" is that side's/seat's own turn; any of move/attack/ability/defend/wait/deploy counts as input. 1v1 reuses the pre-existing per-side `state.idle` counter (already kept for the cosmetic 3-turn "away" notice) at a stricter threshold: `advance_turn` now takes a third `p_timeout boolean` argument, and two consecutive turns ending via `p_timeout=true` with nothing touched (`v_did=false`) sets `state.winner`/`matches.winner` to the other side, `state.forfeitedBy` to the AFK side, and finishes the match (ranked: `finish_match(..., 'abandon')`, the same reason `claim_win` already uses for this kind of ending — no new reason string). The bot's own turn is explicitly excluded from ever counting (`not (m.bot is not null and v_who = 'guest')`), guarding the edge case of a slow/delayed `bot_step` leaving the clock to run out. Royale mirrors this with `royale_players.last_acted_turn` (the 0048 hook, read for the first time here) and a new `idle_streak int` column on the same table; two AFK turns in a row eliminates the seat exactly the way a king's death does (units wiped, `eliminated=true`), and the match finishes early if that leaves one seat standing. `force_timeout_royale(p_match)` is a new function, royale's sibling of the pre-existing `force_timeout`, called from the same client-side clock-enforcement effect `Match.tsx` already had (now duplicated onto `RoyaleMatch.tsx`, which previously had no expiry-enforcement at all — its countdown was display-only).

**Stalemate draw** — "a round" is one full cycle of every living side/seat's turn; 1v1 detects a completed round the instant turn ownership returns to `'host'` (host always opens turn 1, so host/guest strictly alternate for the match's whole life); royale detects it the instant ownership returns to the lowest surviving seat number (self-correcting across eliminations, no separate anchor to maintain). A `state.roundDmg` boolean latches `true` the instant `cn_attack`/`cn_ability` (and their royale twins) resolve **any** damage greater than zero to **anyone**, including self-inflicted burn — reset to `false` each time a round completes. Five consecutive rounds with the latch never set ends the match a draw: `matches.winner='draw'` (the `matches_winner_check` constraint was widened to allow it) or `royale_matches.draw=true` (a new column, since `winner_seat` was already nullable and reusing null would have been indistinguishable from "not over yet"). A draw **deliberately bypasses `finish_match` entirely** — no LP moves either direction for a ranked match — and `cn_match_finished`'s bracket-advance trigger now returns early on `new.winner = 'draw'` rather than trying to credit a tournament win nobody earned (a stalemate draw in a tournament match finishes that match with no winner but does **not** advance the bracket — no tie-break rule exists yet; a real gap, not a lie by omission).

Client: `MatchRow.winner`/`MatchState.winner` widened to `Side | 'draw' | null`, plus new `MatchState.forfeitedBy?: Side | null`; `RoyaleMatchRow.draw: boolean` and `RoyalePlayerRow.idle_streak: number` added. `Match.tsx`'s verdict block and win/lose sound effect both special-case `'draw'` (a draw plays neither fanfare) and call out `forfeitedBy` explicitly rather than reading like an ordinary combat result. `RoyaleMatch.tsx` gained its own clock-tick + `force_timeout_royale` effect and a banner that checks `match.draw` first, then scans the last two `state.log` lines for the literal forfeit message (there is no separate structured `forfeitedSeat` flag — the log text, already written for the human-readable feed, doubles as the client's only signal here, a deliberate choice over a second live-migration for one more field). New i18n keys in both `en.json`/`es.json`: `match.stalemateDraw`, `match.forfeited`, `royale.stalemateDraw`, `royale.forfeitWinnerIs`.

**Live-tested directly against production** with fully synthetic, disposable fixtures (throwaway `auth.users`/`profiles` rows and `matches`/`royale_matches`/`royale_players` rows, all deleted again immediately after — zero real user or match data touched): a 1v1 match forfeited correctly on the second of two consecutive AFK turns (`winner='guest'`, `forfeitedBy='host'`); a 1v1 match auto-drew correctly on the 10th `advance_turn` call (5 rounds) with `roundDmg` never set (`winner='draw'`, `staleRounds=5`); a parallel run that flipped `roundDmg=true` every third call proved the same match stays `active` through 14 turns without falsely drawing; and a 2-seat royale match forfeited seat 0 on schedule (`eliminated=true`, `idle_streak=2`, `winner_seat=1`) with the round-boundary math (`staleRounds=1`) landing exactly where expected along the way.

**Known gaps, stated plainly**: the 0049 effects-engine's `ON_ABILITY`/scripted-action damage path does not yet feed `roundDmg` in either mode (only the legacy inline `cn_ability`/`cn_attack` damage paths do — a scripted-only ability card could in principle stall the stalemate counter; none of the currently-ported cards hit this, per 0050's own card list, but a future one might); a stalemate draw in a tournament match does not advance the bracket (see above); royale has no structured forfeit flag, only the log-text detection described above; the full live smoke tests exercised `advance_turn`/`advance_turn_royale` directly and `roundDmg`'s *consumption*, not a full live `cn_attack` call end to end (verified instead by source review — the spliced line is unconditional on `(v_dmg + v_counter + v_riposte + v_burn_atk + v_burn_tgt) > 0`, right after the existing `fx` write, on the same path every attack already takes).

### Bots in Battle Royale (`0052_royale_bots.sql`)

A bot seat is nothing new at the schema level — `royale_players.user_id` was already nullable since 0048, so this only adds `royale_players.bot int`, the exact same 1/2/3 CALM/SHARP/RUTHLESS encoding `matches.bot` has always used, read by the exact same `bot_name()`. Two entry points, per the developer's ask: a host in a Vs-Friends room can now fill any empty seat 1-3 with a bot before starting (`add_royale_bot`/`remove_royale_bot`, host-only — same seat-0 check `start_royale_match` already used — and only while `status='waiting'`), and the Vs Bots screen gained its own royale picker (1-3 opponents, one shared difficulty rather than one per bot, deliberately — "simpler is fine" was the call made here) that calls `create_royale_bot_match(p_levels)`: seats the caller at 0 via the existing `create_royale_match()`, adds a bot per level through `add_royale_bot`, and starts the room through the existing `start_royale_match()` unchanged — no duplicate deploy/board-generation logic anywhere in this path.

**The interesting question going in was whether `bot_step` makes one decision per call or plays out a whole turn at once** — reading it settled that immediately: one action per call, full stop, with `Match.tsx`'s `setTimeout(() => botStep(...).then(refresh), 650)` re-firing on every `match.updated_at` change and stopping itself the instant the turn moves on. That answered the harder design question for free — since only one seat ever holds the turn at a time even with three bots seated, there is no simultaneous-bots problem to solve, only "whichever seat currently has the turn, drive it the same way." `RoyaleMatch.tsx` now carries the identical idiom (`royaleBotStep(match.id, turnSeat)`, same 650ms delay, same `updated_at`-keyed effect), checking `royale_players.bot` for whoever `state.turn` currently points at.

**`royale_bot_step(p_match, p_seat)` is a direct, line-for-line port of `bot_step`'s decision logic**, fetched fresh from production immediately before writing it (per this project's "copy, don't retype" rule for anything duplicated), with `'guest'` generalised to an int seat, `cn_move`/`cn_attack` swapped for `cn_move_royale`/`cn_attack_royale`, and `advance_turn` for `advance_turn_royale`. Every helper the scoring math calls (`cn_reach`, `cn_cheb`, `cn_los_clear`, `cn_acts_cap`) was already side-agnostic and needed no changes at all. One faithful limitation carried over on purpose rather than improved on the way through: `bot_step` itself never calls `cn_defend`/`cn_ability` — it only ever moves, attacks, or ends the turn — so a royale bot doesn't defend or use abilities either. That is what the 1v1 bot has always done, not a new gap this migration introduced.

**A genuine pre-existing bug turned up while wiring this in, and got fixed in the same migration rather than left for later**: 0051 added `advance_turn_royale(p_match, p_note, p_timeout default false)` but never dropped the original 2-argument `advance_turn_royale(p_match, p_note)` from 0048 — Postgres treats those as two separately overloaded functions, not one replacing the other, and `submit_royale_end_turn` (the ordinary "End turn" button every human royale player has always used) was still calling the 2-argument one, which carries none of 0051's AFK-forfeit or stalemate-round tracking. Only `force_timeout_royale`'s 3-argument call ever exercised the real one. Left alone, a mixed human/bot match would have tracked `staleRounds`/`idle_streak` inconsistently depending on whether a turn ended by a human's button or a bot's step — so the dead 2-argument overload is dropped in 0052 and `submit_royale_end_turn` now calls the 3-argument one with `p_timeout=false`, exactly the voluntary-end semantics it always meant to have. `advance_turn_royale` also picked up one small, deliberate addition of its own: a bot seat is now excluded from the AFK-forfeit block entirely, mirroring 1v1's existing `not (m.bot is not null and v_who = 'guest')` guard — without it, a bot seat whose `royale_bot_step` call ever landed a beat later than the 30-second turn clock could have been forfeited by `force_timeout_royale` for a delay that was never its doing.

A bot's deployment needed no new UI at all: `start_royale_match` already builds every seat's `pendingUnits` with real, valid `x`/`y` positions via `cn_royale_army` before deployment even opens, so a bot has nothing left to decide — it is simply marked ready the instant deployment starts, through a new `cn_royale_mark_ready(p_match, p_seat, p_name)` that is `set_royale_ready`'s own fold-into-battle logic extracted so a bot seat can use it too, byte-for-byte the same statements, without a second copy of that logic drifting out of sync. `start_royale_match` also had to stop calling `deck_of(rp.user_id)` unconditionally, since a bot's `user_id` is null — it now calls `random_deck()` for a bot seat instead, the same call `create_bot_match` already makes for the 1v1 bot's army.

**Live-tested directly against production** with the same synthetic-fixture discipline 0051 used (throwaway `auth.users`/`profiles` rows, `royale_matches`/`royale_players` rows, all deleted immediately after): `create_royale_bot_match(ARRAY[1,2,3])` seated one real host plus CALM/SHARP/RUTHLESS at seats 1-3, all three bots already `ready=true` the instant the room reached `deploying`; the host's own `set_royale_ready` then folded it straight into `active` battle with 20 units on the board. Thirty rounds of alternately calling `royale_bot_step` for whichever bot seat held the turn and `submit_royale_end_turn` for the host's own produced a real, watchable battle — units advancing, landing hits for real rolled damage, several outright kills (unit count dropping from 20 to 16), and turn ownership rotating correctly across all four seats turn after turn with no stalls or errors. `add_royale_bot`/`remove_royale_bot` were verified separately on a plain two-seat room (bot added at seat 1, confirmed in `royale_players`, then removed, seat freed again) and the host-only gate was confirmed to reject a non-host caller. Every test row was deleted afterward; a follow-up count against both throwaway ids and both match rows came back zero.

Client: `RoyalePlayerRow.bot: number | null` (types.ts); `addRoyaleBot`/`removeRoyaleBot`/`createRoyaleBotMatch`/`royaleBotStep` (api.ts); `RoyaleLobby.tsx` gained a host-only, `waiting`-only "Add bot" button per empty seat plus a shared difficulty `.seg` picker above the list (the segmented-control CSS already existed, unused, from an earlier settings pass) and a "Remove" button on any seated bot; `Lobby.tsx`'s Vs Bots page gained a bot-count `.seg` (1-3) and difficulty `.seg` plus a "Start battle royale" button calling `createRoyaleBotMatch`; `RoyaleMatch.tsx` gained the bot-driving effect described above plus a small `(bot)` tag next to a bot's name in both the lobby seat list and the in-battle header. New i18n keys, both `en.json`/`es.json`: `royale.addBot`, `royale.botDifficulty`, `royale.botTag`, `royale.numBots`, `royale.vsBotsStart`, `royale.vsBotsNote`.

**Known gaps, stated plainly**: bot difficulty is shared across every bot in a given royale match, not per-seat — the schema (`royale_players.bot`) supports per-seat levels fine, `add_royale_bot` already takes its own level per call, and the Vs-Friends room picker really is per-seat; only the Vs Bots screen's own picker applies one level to all bots it creates, a deliberate simplicity call rather than a limitation of the RPCs underneath. A royale bot never defends or uses an ability, exactly like the 1v1 bot it was ported from — improving that would mean improving `bot_step` itself first, which is out of scope here. `royale_bot_step` has no auth check at all, matching `bot_step` exactly (both are "anyone can nudge whichever seat's turn it actually is" by design, the same way `force_timeout_royale` is safe for any client to call) — it is not a new hole, but worth knowing if this code is ever read in isolation.

### Still to do (open, not started)

- Extend the card-effects engine's targeted-trigger path with range/LOS enforcement so Sinie/Velmor/Ashvar can be safely ported, and add real actions for `SUMMON_OBJECT`/mist-equivalent so Mako/Fey/Lumea/Eva can be too.
- Dispatch the accepted-but-unwired triggers (`ON_COUNTER`/`ON_KILL`/`ON_HEALED`/`ON_DAMAGED`/`ON_STATUS_APPLIED`) from `cn_attack`, and implement the accepted-but-no-op actions (`REVIVE`/`REFLECT_DAMAGE_PCT`/`SUMMON_OBJECT`/`DRAW_CARD`).
- Royale: turn-based status ticking (poison/regen/mist), hidden deployment, 4-way screen rotation.
- Add a test-suite assertion pinning `cn_is_super_admin()`'s email check specifically, so the 0047 regression class can't repeat silently (see the security incident above).
- `npm run build` (Vite/Rollup) currently fails in the cloud sandbox used for this session on a `@rollup/rollup-linux-arm64-gnu` optional-dependency resolution issue, unrelated to any of this session's changes — `npx tsc -b` (typecheck) passes clean on every file touched. Verify a real `npm run build` on Jared's own machine before deploying.

### Final verification pass and a small hotfix (`0053_hotfix_royale_search_path.sql`)

After 0043-0052 were all live, a verification pass (`npx tsc -b` clean across the whole repo; `get_advisors` security scan; a manual check that `cn_is_super_admin()` still matches its 0039 original byte-for-byte, given the 0047 incident above; row counts on `profiles`/`match_results` confirmed unchanged from session start, so nothing real was lost along the way) turned up one loose end: eight royale helper functions from 0048 (`cn_own_royale`, `cn_royale_zone`, `cn_royale_gen_trees`, `cn_royale_fresh_map`, `cn_royale_army`, `royale_side_of`, `cn_begin_act_royale`, `cn_end_act_royale`) were still missing a fixed `search_path`, despite an earlier agent's report claiming this was fixed. None of the eight are `SECURITY DEFINER`, so this was never a real privilege-escalation path (search_path hijacking's actual danger is against a definer running with elevated rights), but it was closed anyway with eight `ALTER FUNCTION ... SET search_path = 'public'` statements — no function body touched, zero behavior change. `get_advisors` no longer flags any of the eight.

Two pre-existing findings were confirmed to predate this whole session and were left alone: `match_presence`/`ranked_queue` having RLS enabled with no policies (deliberate, from 0003/0007 — both tables are reachable only through their own RPCs) and `cn_effect_dmg` missing a fixed search_path (a 0034 function, not touched this session).

**As of this line, migrations 0043 through 0054 are all live in production and match the files in `supabase/migrations/` exactly** (0054 applied directly via the Supabase MCP tools, then verified with `execute_sql` -- see 0054's own paragraph above for what it does and how it was tested). Everything under "Still to do" above remains genuinely open.

## 10. Card delete bug fix — retiring-first requirement dropped (`0055_delete_active_cards.sql`, 2026-09-17)

Jared reported: in the admin card editor, "Delete permanently" still failed
with *"X must be retired (untick 'In the game' and save) before it can be
deleted permanently"* even right after unticking "In the game" — and he did
not want that step at all; he wants delete to just delete, behind a
confirmation pop-up (which already existed).

**Root cause, found by reading the code rather than guessing:**
`AdminCards.tsx` was showing the "Delete permanently" button off
`!draft.is_active` — the unsaved checkbox state sitting in the form — not off
the row actually saved on the server. So unticking the box made the button
appear at once, but the database row was still `is_active=true` until Save
was pressed; clicking delete right after unticking called
`admin_delete_card()` while the server still saw the card as active, and the
function (correctly, per its own 0046 logic at the time) refused it. That is
why it looked like unchecking the box "did nothing."

**Fix, matching what Jared actually asked for (not a client-side patch to
enforce save-before-delete, but removing the requirement):**
- `0055_delete_active_cards.sql` redefines `admin_delete_card()` to drop the
  `is_active` check entirely. **Jared ran this migration against
  production on 2026-09-17.** The three checks that are not a style
  preference are unchanged and still run: not in anyone's `profiles.deck`,
  not in any `profiles.kingdoms[].deck`, not on the board in a match that
  has not finished.
- `AdminCards.tsx`'s delete button now shows for any existing card
  (`draft.id !== 'new'`), with no `is_active` gate at all — the confirmation
  dialog ("Really delete X permanently? This cannot be undone.") is the only
  guard left, which is what was asked for.
- `0046_admin_content_and_delete.sql` got a short comment pointing forward to
  0055, since its own inline copy of `admin_delete_card()` is now stale —
  read the function from 0055 onward, not from 0046.

Committed as `8149c65`, "Card delete no longer requires retiring first" — see
that commit for the exact diff (`src/components/AdminCards.tsx`,
`supabase/migrations/0046_admin_content_and_delete.sql`,
`supabase/migrations/0055_delete_active_cards.sql`). `npx tsc -b` was clean
before committing. **Not yet pushed to `origin/main`** — the push-authorization
block described in section 2 ("Pushed and live") still applies; Jared pushes
from his own machine.

Retiring a card (unticking "In the game" and saving) is still there and still
works exactly as before — it is just no longer a precondition for the hard
delete. The two are independent now: retire to pull a card out of play
reversibly, delete to remove a row for good, in either order, with delete
always gated only by the confirm dialog and the three reference checks above.

Left untouched, and not part of this fix: the Battle Royale / AFK-forfeit
in-progress work already sitting uncommitted in the working tree
(`RoyaleBoard.tsx`, `RoyaleLobby.tsx`, `RoyaleMatch.tsx`, `src/lib/api.ts`,
`src/lib/types.ts`, `src/styles.css`) and an untracked
`0054_royale_deploy_fog.sql` — those predate this session and were not
touched or evaluated here.

## 11. "Mad Libs" sentence builder for card abilities/passives and Structures (`0056_ability_sentences.sql`, `0057_structures.sql`, 2026-09-17)

Jared's ask: a visual, pill-based ability editor inside the Admin Menu that
reads left to right like a typed sentence — connector/trigger/target/
action/value/duration/range pills the admin clicks to swap, an Add Block
button to extend a sentence, an Active/Passive toggle above the builder
(Active locks the trigger to "When activated" and shows Max Uses/Cooldown),
and the same builder reused for a brand-new Structures content type with
"stepped on"/"destroyed"/"invoker" among its categories. Four clarifying
questions were asked before anything was built; Jared picked the more
ambitious option on all four: **full live gameplay implementation** (the
engine actually enforces uses/cooldown and runs structure effects during
real matches, not just an authoring screen); the sentence UI **replaces**
`AbilityEditor`, compiling to the same `card_effects` rows `cn_run_effects`
already reads, not a parallel schema; a card may hold **a list of
sentences, each with its own Active/Passive toggle**; Structures are **a
brand-new content type with their own tables**, not folded into the unbuilt
`SUMMON_OBJECT` no-op.

### Server: `0056_ability_sentences.sql`

- `card_effects` gains `group_id uuid not null default gen_random_uuid()`
  (ties every row of one authored sentence together — an existing pre-0056
  row is its own one-row sentence via the column default, so nothing about
  0049/0050's data needed a backfill statement), plus authoring-only
  `duration_kind`/`duration_turns` and `range_kind`/`range_min`/`range_max`
  with check constraints matching the developer's vocabulary. **Read the
  column comments for exactly what each is and is not enforced for yet** —
  `duration_kind='FOR_TURNS'` is real today only for STUN (`cn_afflict`
  already carried a turn count; nothing else changed); on BURNING/POISON it
  is accepted and stored but not separately ticked (those two have always
  been binary "afflicted until cured" flags with no counter anywhere in the
  engine, and adding one is real, separate surgery on
  `cn_afflict`/`advance_turn`/`cn_attack`'s burn-tick logic, deliberately
  not done here); `range_kind='FIXED_RANGE'`'s `range_min`/`range_max` are
  stored but `cn_resolve_targets` still reads the **acting unit's own**
  `rmin`/`rmax` — overriding per-effect range needs a second parameter
  threaded through `cn_resolve_targets`/`cn_run_effects`, noted as a
  follow-up rather than guessed at.
- `card_ability_meta(card_id, group_id, ability_type, max_uses, cooldown_turns)`
  — one row per authored sentence that is Active, **not** more columns on
  `card_effects`, because these three values describe the whole sentence,
  not any one row in it (a 3-row "and" chain under one trigger has one
  cooldown, not three copies to keep in sync). `max_uses` is null=infinite
  or 1-5; `cooldown_turns` is 0-5. **At most one Active sentence per card is
  enforced by a partial unique index** (`card_ability_meta_one_active_per_card`
  on `(card_id) where ability_type='active'`), not left to the UI to
  promise — `cn_ability`/`submit_ability`/the board's own Ability button all
  still assume exactly one activated-ability slot per unit, so the schema
  refuses a second rather than silently drifting from what the client can
  actually do.
- **Cooldown is tracked as "the turn number this was last used," not a
  counting-down field** — a deliberate simplification that keeps this
  migration to `cn_army`/`cn_ability` only, nowhere near `advance_turn`
  (which already carries 0051's AFK-forfeit/stalemate-draw logic and is
  exactly the kind of order-sensitive function this project's own
  conventions say to touch as little as possible). "Ready again once
  `turnNumber - lastUsed > cooldownTurns`" is the same fact a countdown
  would track, computed instead of stored.
- Splices (each fetched fresh via `pg_get_functiondef` against a database
  with 0001-0055 applied, immediately before writing this file, and
  round-trip-verified — `cn_attack`'s real current version turned out to be
  in **0051**, not 0049 as first assumed; caught by re-grepping every
  migration file before splicing rather than trusting an earlier read):
  `cn_army` snapshots `abilityMaxUses`/`abilityCooldownTurns` from
  `card_ability_meta` onto the unit exactly like `abilityScript` already is
  (null for every card with no Active sentence, which is exactly today's
  unlimited-use behaviour — nothing about a pre-0056 card changes);
  `cn_ability` gains the actual enforcement — refuses with `'that ability
  has no uses left this match'` or `'that ability is on cooldown for %
  more turn(s)'` before dispatching, then bumps `abilityUses`/
  `abilityLastUsedTurn` on success, merged back into whichever of the six
  kind-branches' own `v_out` built the response (all six build it
  independently from pre-bump state, so the merge has to happen once,
  after the branch, not inside each one).

### Server: `0057_structures.sql`

A brand-new content type, own tables, reusing the existing
obstacle/combat machinery rather than inventing a second one:

- `structures(id, slug, name, hp, blocks_movement, accent, art_url,
  is_active, sort)` — the catalog, gated by the same admin-write/
  authenticated-read RLS shape every other content table uses.
- `structure_effects(id, structure_id, sort, group_id, trigger,
  target_selector, action, value, status, stat_name, conditions,
  duration_kind, duration_turns)` — built to mirror `card_effects` column
  for column on purpose, which is what lets `SentenceBuilder.tsx` serve
  both screens. `trigger` is `ON_STEPPED_ON`/`ON_DESTROYED`/`ON_PLACE`/
  `PASSIVE`; `target_selector` adds `INVOKER` (whoever placed it, looked up
  by still being alive) and `WHOEVER_STEPPED` (the unit from the trigger's
  own context) to the same 14 non-tile selectors card sentences use;
  `action` is the 7-member subset of `card_effects.action` that makes
  sense for something standing on the ground (no `TELEPORT_SELF`/
  `SWAP_POSITIONS`/etc). **No `range_kind` column at all** — a structure's
  own trigger already answers the range question (`ON_STEPPED_ON` reaches
  whoever is standing on it, the rest reach outward from where it stands),
  so Range was left off rather than added as a control with nothing under
  it to save.
- `card_effects.structure_slug` (fk to `structures.slug`) + a new
  `'CREATE_STRUCTURE'` member on `card_effects.action` — this is how a card
  places one: an `ON_ABILITY`/`BOARD_CELL` sentence with
  `action='CREATE_STRUCTURE'` and `structure_slug` set.
- `cn_obj_solid`/`cn_obj_hp`/`cn_obj_name` (0035) changed from `immutable`
  to `stable` and given a `structures` fallback for any kind that isn't one
  of the four legacy ones — **the four legacy kinds (tree/wall/bomb/
  tornado) are provably unchanged**, confirmed by the migration's own
  verification block and re-checked by `31_structures.sql`.
- New functions, all additive: `cn_resolve_structure_targets` (handles
  `INVOKER`/`WHOEVER_STEPPED` itself, delegates every other selector to the
  existing `cn_resolve_targets` via a synthesized fake unit standing where
  the structure stands); `cn_run_structure_effects` (looks up the
  structure's catalog row by `cn_obj_kind`, no-ops instantly if there isn't
  one — the reason legacy obstacles are completely unaffected — otherwise
  loops matching `structure_effects` rows, checks conditions, resolves
  targets, applies via the **existing** `cn_effect_apply_action`, reading
  `structure_effects` live rather than from a snapshot, matching how
  `cn_obj_hp` has always been read live for obstacles); `cn_create_structure`
  (validates the tile, board bounds, and occupancy, silently no-ops on
  failure — the same convention every other action-family function in this
  engine already follows rather than raising); `cn_step_on_structure`
  (finds a structure-kind obstacle at a unit's tile and fires
  `ON_STEPPED_ON`); `admin_delete_structure` (refuses while the slug is
  standing as an obstacle in any unfinished match, mirroring
  `admin_delete_card`'s own "not live anywhere" checks).
- Splices: `cn_army` snapshots `structure_slug` onto `abilityScript` rows
  alongside every other `card_effects` column; `cn_effect_apply_action`
  gains one new branch inside its existing `left(p_target_id,1)='@'` tile
  block, `CREATE_STRUCTURE` → `cn_create_structure`, right before that
  block's existing "anything but TELEPORT_SELF returns unchanged" line;
  `cn_spring` (called from `cn_move`) gets `cn_step_on_structure` inserted
  **before** its existing early return for "no bomb here" — the one
  genuinely order-sensitive change in this file, since a tile can now
  matter even when there's no bomb trap on it; `cn_attack` (0051's real
  current body, re-fetched) gets one additive block right after its
  existing `-- ===== end 0049 =====` marker: if the thing just destroyed
  was a tree-family obstacle, fire `ON_DESTROYED` through
  `cn_run_structure_effects`.

### Testing (both migrations)

New test files `30_ability_sentences.sql` (18 assertions) and
`31_structures.sql` (15 assertions), both fully green and confirmed
**idempotent** (run twice back to back against the same database with zero
leftover rows either time). Coverage includes: `group_id` defaulting/
explicit save; `card_ability_meta`'s one-active-per-card unique constraint
(`t_raises 'duplicate key'`); a second Passive sentence allowed on the same
card; the duration/range check constraints; a real runtime flow on Wuzu
(temporarily given a scripted `ON_ABILITY`/heal-self sentence plus
`max_uses=1, cooldown_turns=2`) confirming the snapshot, the use-counter
incrementing, a second activation refused with "no uses left," and a
**separate** match confirming the cooldown refusal on a same-turn-window
re-activation; a card with no `card_ability_meta` row snapshotting
`abilityMaxUses` as null (full backward compatibility); a full structures
runtime flow — Fey (temporarily repurposed with a `CREATE_STRUCTURE`
sentence) places a 'spike-trap' via a real `cn_ability` call, an enemy unit
walks onto it via a real `cn_move` and gets poisoned (and nothing else on
the board does), then it's destroyed via a real `submit_attack` and Fey
(the `INVOKER`) is healed. Existing tests re-run with both migrations
applied and showed **no new regressions**: `26_summons.sql`,
`27_the_throw.sql`, `07_abilities.sql`, and `30_ability_sentences.sql`
itself all pass cleanly; `24_abilities.sql` shows the same one pre-existing
flaky assertion ("and the tree beside them takes it too" — random
tree-placement driven) that was independently confirmed to reproduce
identically on a database **without** 0056/0057 applied.

**Two pre-existing bugs were found during this work, confirmed to predate
this session, and deliberately left unfixed (out of scope for this task,
reported here rather than silently worked around):**

- `cn_attack`'s 0045 single-class-achievement check
  (`select count(*), array_agg(...) from jsonb_array_elements(v_out) u
  where ...`) hits `column reference "u" is ambiguous` whenever
  `v_win_uid is not null` is reached — a bare `SELECT`, not a `FOR` loop,
  whose `FROM`-alias `u` collides with a PL/pgSQL-declared variable also
  named `u`, which this database's default
  `plpgsql.variable_conflict = 'error'` rejects. Reproduces identically on
  a database with none of this session's migrations applied. Not touched,
  per this project's own stated risk-avoidance around `cn_attack`.
- Several roster-count test assertions ("eleven units in the roster," "ALL
  TWENTY UNITS OF THE SPEC ARE PLAYABLE") fail on a full sequential test-
  suite run, independent of this session's changes — reproduces on a clean
  database with none of 0056/0057 applied. Matches `project_status.md`'s
  own existing caveat elsewhere in this file about the full suite not
  reliably reading 100% green.

Both migrations and their test files were committed into
`supabase/migrations/` and `supabase/tests/` on Jared's machine (not yet
`git commit`ed — see section 2's push-authorization note; that step is
Jared's, same as every other migration in this file).

### Client

- **`src/lib/types.ts`**: `CardEffect` gains `group_id`, `duration_kind`,
  `duration_turns`, `range_kind`, `range_min`, `range_max`,
  `structure_slug`; new `CardAbilityMeta`, `Structure`, `StructureEffect`
  interfaces; `Unit` gains `abilityMaxUses`/`abilityCooldownTurns`
  (snapshotted cost, mirroring `abilityScript`) and
  `abilityUses`/`abilityLastUsedTurn` (per-unit runtime counters, mutated
  over the match exactly like `hp`/`moved`/`acted` already are).
- **`src/components/SentenceBuilder.tsx`** (new, shared) — the actual
  pill-based Mad-Libs UI, used by both AdminCards.tsx and
  AdminStructures.tsx, since `card_effects`/`structure_effects` share the
  same trigger/target/action/value/status/stat_name/conditions/duration
  shape by design. Every clickable pill is an ordinary `<select>` styled
  to read as a word; "When [Trigger] if [Condition] and [Condition]..." is
  one row, "then [Target] [Range] [Action] [Value] [Status/Stat]
  [Duration]" is a clause row, "and [Target]..." chains another clause
  under the same trigger/conditions via **Add Block**, and **+ New
  sentence** appends a whole new group. **Scope call, stated in the
  component's own header**: "Add Block" appends another target+action
  clause rather than an arbitrary block of any category in any order,
  because the schema underneath is not that free — a row is always
  trigger + conditions + target + action + duration, since that is the
  shape `cn_run_effects`/`cn_run_structure_effects` actually read. Every
  individual word is still a real, independently swappable pill, which is
  the part of the spec that maps onto something the engine runs. "Or" is
  named in the developer's original vocabulary but not offered as a
  control anywhere — `cn_effect_condition_met`/`cn_effect_conditions_met`
  evaluate every condition as AND with no OR branch in the engine at all,
  and a connector that didn't do what it said would be a worse outcome
  than not offering it, the same honesty 0049's `ACTION_NOOPS` already
  established for `REVIVE`/`SUMMON_OBJECT`/etc.
- **`src/components/AdminCards.tsx`** — `AbilityEditor` rebuilt on
  `SentenceBuilder`: each sentence gets its own Active/Passive toggle
  (Active locks the trigger pill to a plain "activated" badge and reveals
  Max Uses — Infinite or 1-5 — and Cooldown — 0-5 turns — fields backed by
  `card_ability_meta`; toggling a second sentence to Active client-side
  demotes whichever one was Active back to Passive, so the save can never
  hit the server's one-Active partial unique index as a raw constraint
  error). `saveEffects()` now also replaces `card_ability_meta` for the
  card and **auto-manages `cards.ability_kind`**: an `ON_ABILITY` sentence
  existing sets it to `'scripted'`, none existing resets it from
  `'scripted'` back to null — a card whose `ability_kind` is one of the six
  hardcoded kinds (`aoe_adjacent`/`heal_any`/`mist`/`poison_hit`/
  `line_burn`/`summon`) is left alone either way, since this tab has never
  had — and still doesn't have — any control for authoring those six; they
  are set directly in the database, not through this screen.
- **`src/components/AdminStructures.tsx`** (new) — same list/form/Save
  shape as AdminCards.tsx, one form (no Stats/Abilities split — a
  structure has no legacy compiler to keep separate from anything), a
  `SentenceBuilder` for its effects with no Active/Passive toggle
  (structures aren't player-activated). Art is a plain URL text field, not
  an upload picker like cards' `Art` component — a real, deliberate scope
  cut, noted here rather than silently smaller than cards' own screen.
- **`src/components/AdminPanel.tsx`** — new "Structures" tab between Cards
  and Music.
- **`src/lib/api.ts`** — `adminDeleteStructure()`, calling the new
  `admin_delete_structure` RPC, same shape as `adminDeleteCard`.
- **`src/components/Board.tsx`** — a real gap was found and fixed here,
  not merely display polish: a `'scripted'` Active ability (the whole
  point of this feature) had **no client-side firing path at all** before
  this pass — `fireAbility()`'s old logic only recognized
  `aoe_adjacent`/`mist` as "fires straight off the menu" and everything
  else fell through to doing nothing on click. Fixed by: any scripted
  ability whose `ON_ABILITY` sentence does **not** target `BOARD_CELL`
  resolves entirely server-side (every other selector — `SELF`,
  `ALL_ENEMIES`, `NEAREST_ENEMY`, etc — is resolved by
  `cn_resolve_targets` from the selector alone, same as it always has
  been) and now fires immediately, the same as `aoe_adjacent`/`mist`; one
  that **does** target `BOARD_CELL` gets a new `scriptTiles` lit-tile set
  (same reach rule as the six hardcoded kinds' own `summonTiles`: the
  unit's own `rmax`, line of sight, nothing already standing there) and
  fires with the same `'@x,y'` wire convention `CREATE_STRUCTURE`/
  `TELEPORT_SELF` already use. The Ability button also now reads
  `abilityMaxUses`/`abilityUses`/`abilityCooldownTurns`/
  `abilityLastUsedTurn` off the snapshot and goes disabled — with a
  tooltip naming which — the same instant `cn_ability` itself would refuse
  it (uses left / cooldown remaining), plus a small badge
  (`3/5`, `⏳2`) on the button itself so a player isn't left guessing why
  it's dim. New `en.json`/`es.json` keys: `board.abilityNoUses`,
  `board.abilityCooldown`.
- **`src/lib/objects.ts`** — `ObjKind` widened from a fixed 4-member union
  to `string`, since a `kind` can now be any structures-catalog slug
  (mirrors `cn_obj_kind`'s own server-side fallback); `objNameKey` no
  longer mislabels an unrecognised kind as `'obj.tree'` (returns `''`, and
  the caller in `Board.tsx` falls back to the raw kind string); `ThingGlyph`
  gets a real generic fallback shape instead of silently drawing the
  tornado funnel for anything it doesn't recognise (which is what a custom
  structure got before this pass).

### Known gaps, stated plainly — the same honesty this file already uses
for `ACTION_NOOPS`/etc, not a lie by omission

- **`objSolid` does not consult the structures catalog** — a custom
  structure's own `blocks_movement` is not read client-side, so the
  move/line-of-sight *preview* can be wrong for a structure with
  `blocks_movement=true` (it previews as walkable/shootable-over). The
  server (`cn_obj_solid`, read live, never snapshotted) is what a match
  actually enforces, so the only real consequence is a rejected-move
  round-trip, not an illegal move landing. Doing this correctly needs the
  structures catalog threaded through `trees()`/`losClear()`/
  `legalMoves()` in `rules.ts` and `rulesRoyale.ts` — real, separate
  surgery on the client's own most order-sensitive geometry code, not
  attempted in this pass. See `objects.ts`'s own comment on `objSolid`.
- The board draws no per-structure art or display name from the catalog —
  `objNameKey` falls back to the raw slug (e.g. "spike-trap") rather than
  the catalog's own `name` ("Spike Trap"), and `ThingGlyph` draws one
  generic mark for every custom structure rather than reading
  `structures.art_url`. Fetching the catalog client-side for this is a
  real, bounded follow-up, not done here.
- `range_kind='FIXED_RANGE'`'s `range_min`/`range_max` and
  `duration_kind='FOR_TURNS'` on BURNING/POISON are authoring metadata only
  — see 0056's own column comments above for exactly what is and isn't
  enforced today.
- The accepted-but-unwired triggers from 0049
  (`ON_COUNTER`/`ON_KILL`/`ON_HEALED`/`ON_DAMAGED`/`ON_STATUS_APPLIED`) and
  no-op actions (`REVIVE`/`REFLECT_DAMAGE_PCT`/`SUMMON_OBJECT`/`DRAW_CARD`)
  are unchanged by this pass — still exactly the gaps section 9 already
  named.
- Royale mode has no ability UI or engine support at all (pre-existing,
  confirmed unrelated to this pass — `RoyaleBoard.tsx` never referenced
  `abilityKind` before or after).
- `npm run build` (the `vite build` half specifically) fails in this
  session's cloud sandbox on a `@rollup/rollup-linux-arm64-gnu`
  optional-dependency resolution error, unrelated to any change in this
  section — `npx tsc -b`/`npm run typecheck` are clean on every file this
  section touched. Same caveat section 9 already recorded for its own
  work; verify a real `npm run build` on Jared's own machine.

## 12. Parry vocabulary added to the sentence builder (`0058_parry_vocabulary.sql`, 2026-09-17)

Jared's ask, right after section 11 shipped: "make sure to also include
Parry options across the builder categories" — Triggers `parries`,
`is parried`, `counter-attacks`; Actions `triggers Parry against`,
`counter-attacks [1-100%] damage to`. Folded into the React component and
database schema, and recorded here per that same request.

### What already existed, reused rather than duplicated

- **`ON_PARRY`** (0049) already meant exactly "parries" — fires from
  `cn_attack` on the unit that caught a blow. No schema change and no new
  dispatch needed; only the Admin UI's pill label changes (see below) so it
  reads "parries" instead of the raw constant.
- **`ON_COUNTER`** (0049) was already in the trigger enum and the admin
  dropdown, but section 9 said plainly it was "accepted by the schema, not
  yet dispatched from anywhere." **This migration closes that gap** —
  `cn_attack` now actually fires it, off the same `v_swings` array element
  the ordinary counter-swing already produces (`k='hit'`,
  `counter=true`). Asking for a working "counter-attacks" trigger is what
  made fixing this the right call, rather than shipping a second silently-
  fake pill next to the new one this migration adds for real.

### What is genuinely new

- **`IS_PARRIED`** — the mirror of `ON_PARRY`, fired on the *other* unit in
  the same swing: the one whose blow got caught, not the one that caught
  it. Did not exist in any form before this migration. Dispatch is an exact
  structural copy of the existing `ON_PARRY` block, reading `v_elem->>'at'`
  (the unit *being* parried) instead of `v_elem->>'by'` (the unit doing the
  parrying).
- **`TRIGGER_PARRY`** and **`COUNTER_ATTACK_PCT`** — two new Actions.
  Accepted by the schema, visible and swappable in both builders, saved
  correctly — but landed in the *same documented-no-op bucket*
  `cn_effect_apply_action` already keeps for
  `REVIVE`/`REFLECT_DAMAGE_PCT`/`SUMMON_OBJECT`/`DRAW_CARD` (extended list,
  same comment, same function). Forcing a guaranteed parry outcome, or
  landing an authored percentage counter-strike, both mean new state inside
  `cn_attack`'s swing loop — the single most order-sensitive function in
  this codebase — and real surgery on it is not what "fold this into the
  schema" asked for. Labelled `(not built yet)` in both dropdowns exactly
  like their four siblings: a stated scope cut, not a lie by omission.
- **Structures get `COUNTER_ATTACK_PCT` too** (a structure "counter-
  attacking" whoever destroys it — a spike trap that detonates back — is
  thematically coherent even while unbuilt) but **not** the two new
  triggers or `TRIGGER_PARRY`: a structure never rolls a parry chance or
  stands in `cn_attack`'s swing loop as a combatant, so "parries"/
  "is parried" would be vocabulary the structures builder could save but
  that could never mean anything. `structure_effects_action_check` was
  written to accept `COUNTER_ATTACK_PCT` and explicitly **not**
  `TRIGGER_PARRY` — verified by a `t_raises` assertion, not just left out.
  `AdminStructures.tsx` gets its own `ACTION_NOOPS`/`actionLabel` — the
  *first* no-op action a structure has ever had, since every action
  offered there before this was real.
- `COUNTER_ATTACK_PCT`'s `value` is **required and bounded 1-100** (a
  percentage), unlike most other actions' optional `value` — enforced by a
  dedicated check constraint on both tables
  (`card_effects_counter_attack_pct_check` /
  `structure_effects_counter_attack_pct_check`), not left to the UI to
  promise.

### Server: splices into `cn_attack` and `cn_effect_apply_action`

Both fetched fresh via `pg_get_functiondef` against a database with
0001-0057 applied, immediately before writing this migration, and every
splice round-trip-verified (insert via `str.replace()`, then assert
reversing it reproduces the original byte-for-byte) before being pasted
into the migration file.

- `cn_attack` gains two declarations (`v_pd_unit`/`v_pd_id` for
  `IS_PARRIED`, `v_co_unit`/`v_co_id` for `ON_COUNTER`) and two new
  dispatch blocks inside the existing swing-processing loop, both additive
  and both firing after that loop's local scalars are already flushed —
  the same placement discipline the 0049 hooks block already established.
- `cn_effect_apply_action`'s no-op action list gains `'TRIGGER_PARRY'` and
  `'COUNTER_ATTACK_PCT'` — a two-token change to an `in (...)` list, no
  other line touched.

### Tests: `32_parry_vocabulary.sql` — two real bugs found and fixed while writing it

All 10 schema-level assertions pass (every trigger/action accepted, every
bad `COUNTER_ATTACK_PCT` value rejected by name, `TRIGGER_PARRY` rejected
for a structure by name), and both runtime exchanges pass: h1 hits g1,
g1's ordinary counter fires `ON_COUNTER` for real (57 hp, not 60), and a
second exchange proves `ON_PARRY`/`IS_PARRIED` are the two honest halves of
one caught blow (h2 53 hp from its own parry-heal, g2 54 hp from its
*own* blow being caught — g2 took no damage at all, since the swing never
got past the parry). Two bugs surfaced chasing these down, both fixed in
the test file itself, neither in the engine:

- **A prior run that died mid-file left stale `card_effects` rows behind.**
  `\set ON_ERROR_STOP on` means a failed assertion aborts before the
  file's own end-of-file cleanup ever runs. A second leftover copy of the
  throwaway `ON_COUNTER`/`HEAL`/7 row on Dereo silently doubled the heal
  the very next run asserted on (g1 landed on 78 hp, not 57 — traced by
  querying the unit's snapshotted `abilityScript` directly and finding the
  same row four times over). Fixed by deleting each throwaway row
  defensively *before* inserting it, not only after — the same
  belt-and-suspenders the schema block above already used for its own
  `sort >= 900` rows.
- **`t_match()` snapshots each unit's `abilityScript` from `card_effects`
  once, at match-creation time.** The `ON_PARRY`/`IS_PARRIED` throwaway
  rows were originally inserted down by their own exchange — after
  `t_match()` had already run — so h2/g2/g3 played out the whole thing
  with no ability script at all, and the hp assertions failed silently
  wrong rather than loudly missing. Fixed by moving every throwaway row
  (all three, for both exchanges) up before the file's single `t_match()`
  call. A second, smaller fix alongside it: `submit_attack` checks both
  whose turn it is and that the caller owns the attacking unit, so the
  second exchange (guest's unit attacking) needed `app.uid` switched back
  to the guest and `state.turn` flipped by hand — `t_reset()` clears the
  per-unit flags and the turn's activation budget but deliberately leaves
  whose turn it is alone (see that function's own comment), which this
  file is the first to need across two different attacking sides in one
  match.
- Confirmed idempotent — reran the file twice in a row from the same
  database state with no manual cleanup in between, both green.

**Regression check**, run against `09_combat.sql`, `11_swings.sql`,
`12_clock.sql`, `07_abilities.sql`, `24_abilities.sql` with 0058 applied:
two pre-existing failures (`09_combat.sql`, `12_clock.sql`, both
`column reference "u" is ambiguous"` inside `cn_attack`'s own win-condition
count) and one pre-existing flaky test (`07_abilities.sql`'s bot-simulation
assertion, ~35% fail rate over 16 runs) were all confirmed **unrelated to
this migration** by reverting to the exact pre-0058 `cn_attack`/
`cn_effect_apply_action` bodies and reproducing the identical failures —
same error, same line, same flake rate — before restoring the spliced
versions. Not fixed here; flagged for whoever picks up `09_combat.sql`/
`12_clock.sql` next, since "ambiguous column" inside the single riskiest
function in the codebase is worth knowing about even though this migration
didn't cause it and isn't the place to fix it.

### React: `SentenceBuilder.tsx`, `AdminCards.tsx`, `AdminStructures.tsx`, `lib/types.ts`

- **`lib/types.ts`** — `CardEffect.trigger` gains `'IS_PARRIED'`;
  `CardEffect.action` and `StructureEffect.action` gain
  `'TRIGGER_PARRY'`/`'COUNTER_ATTACK_PCT'` (cards) and
  `'COUNTER_ATTACK_PCT'` (structures). Incidental fix noticed while editing
  this same union: `CardEffect.action` was missing `'CREATE_STRUCTURE'`
  entirely — a real pre-existing gap from 0057 (the column comment already
  referenced it two lines below; the union type itself just never got it) —
  added alongside this migration's own two entries rather than left
  sitting next to them, uncorrected, in the same block.
- **`SentenceBuilder.tsx`** — `NO_VALUE_ACTIONS` gains `'TRIGGER_PARRY'`
  (no numeric parameter, same bucket as `REVIVE`/etc; `COUNTER_ATTACK_PCT`
  is deliberately *not* added here, since its value is real authoring data
  even though the engine doesn't act on it yet). New optional
  `actionLabel?: (a: string) => string` on `SentenceVocab`, same shape as
  the pre-existing `triggerLabel` — the action Pill's `labelFor` now reads
  `vocab.actionLabel?.(a) ?? a` before appending the existing
  `(not built yet)` suffix, rather than always showing the raw constant.
- **`AdminCards.tsx`** — `TRIGGERS` gains `IS_PARRIED`; `ACTIONS` gains
  `TRIGGER_PARRY`/`COUNTER_ATTACK_PCT`; `ACTION_NOOPS` gains both (so they
  render `(not built yet)`, same as their four siblings).
  `PASSIVE_TRIGGERS` (a filter over `TRIGGERS`) picks up `IS_PARRIED`
  automatically — no separate edit needed there. New `TRIGGER_LABELS`/
  `triggerLabel` and `ACTION_LABELS`/`actionLabel` maps, wired onto
  `CARD_VOCAB`. **Deliberately partial, not exhaustive**: only the three
  triggers and two actions Jared actually named by their English text get
  an entry (`ON_PARRY`→"parries", `IS_PARRIED`→"is parried",
  `ON_COUNTER`→"counter-attacks", `TRIGGER_PARRY`→"triggers Parry against",
  `COUNTER_ATTACK_PCT`→"counter-attacks % damage to" — the value box
  rendered right after that pill stands in for the developer's own
  "[1-100%]" bracket). Every other trigger/action still reads as its own
  raw constant; relabelling the other thirteen triggers nobody asked to
  have reworded would have been a much bigger, unrequested change riding
  along on a "quick addition."
- **`AdminStructures.tsx`** — `ACTIONS` gains `COUNTER_ATTACK_PCT`; new
  local `ACTION_NOOPS`/`ACTION_LABELS`/`actionLabel` (structures had no
  no-op action, and therefore no such set, until this migration), wired
  onto `STRUCTURE_VOCAB` the same way `AdminCards.tsx`'s are.
- `npx tsc -b` is clean on every file this section touched.

### Known gaps, stated plainly

- `TRIGGER_PARRY` and `COUNTER_ATTACK_PCT` are accepted, saveable, and
  visibly labelled `(not built yet)` — but do **nothing** at runtime. See
  "what is genuinely new" above for exactly why, and `cn_effect_apply_action`'s
  own comment for the same statement server-side.
- The other four accepted-but-unwired triggers from 0049
  (`ON_KILL`/`ON_HEALED`/`ON_DAMAGED`/`ON_STATUS_APPLIED`) are unchanged by
  this pass — `ON_COUNTER` is the only one this migration moved from
  "accepted" to "real."
- `09_combat.sql`/`12_clock.sql`'s pre-existing `"column reference \"u\" is
  ambiguous"` failure and `07_abilities.sql`'s pre-existing bot-simulation
  flakiness are both confirmed unrelated to this migration (see the
  regression-check paragraph above) but neither is fixed here — still open
  for whoever picks them up next.

## 13. Human-readable Mad-Libs labels, EVASION_PCT, flat-HP conditions, and Flies/Slippery cleanup (`0059_evasion_and_labels.sql`, 2026-09-17)

Jared's ask: the sentence builder's pills were showing raw database
constants (`MODIFY_STAT`, `self.hp_pct`, `CARD_RANGE`) instead of English,
breaking the "reads like a sentence" point of the whole builder; the
Cards admin's HP condition should offer both a flat-value and a
percentage-value option, not just percentage; the Stats and Abilities &
Passives tabs should sit next to each other; Flies should be removed
entirely; and Slippery should come out of the builder's vocabulary in
favour of a real Evasion property. A clarifying question was asked on the
last point — a safe rename of Slippery to Evasion with zero engine changes,
or a brand-new dodge-chance stat requiring real `cn_attack` surgery — and
Jared picked the second, more expensive option: **`EVASION_PCT` is a new
stat, separate from Parry, with its own roll in combat.**

### Server: `0059_evasion_and_labels.sql`

- `cards.evasion_pct` — a new `int not null default 0` column, `0-100`,
  checked the same way `parry_pct`/`crit_pct` already are
  (`cards_evasion_pct_check`). Compiled from a PASSIVE/`MODIFY_STAT` row
  the same way `TWICE_PCT`/`REGEN_PCT` already are — `EVASION_PCT` has none
  of the nine stat_names' RUNTIME-ONLY exclusion problem (no
  `cn_check_card` trigger recomputes it, nothing double-counts it on an
  unrelated `card_effects` edit), so it is a normal compiler-owned stat,
  reset to 0 and re-derived on every `cn_compile_card_effects(card_id)`
  call like any other.
- `card_effects_stat_name_check` gains `EVASION_PCT`. **`SLIPPERY` and
  `FLIES` stay in this list** — this migration only removes them from
  `AdminCards.tsx`'s offered vocabulary, not from the schema. Himanta's
  existing card carries a live `SLIPPERY` row and `cn_attack` still reads
  it in four places; an already-saved `FLIES` row (if any card ever had
  one) still round-trips too. Test `33_evasion_and_conditions.sql` checks
  both still insert cleanly.
- `cn_effect_apply_action`'s `v_num_field_map` gains
  `"EVASION_PCT": "evasionPct"` — so a structure or an `ON_ABILITY`/etc.
  effect can also *grant* temporary evasion at runtime, the same door
  `TWICE_PCT`/`REGEN_PCT` already use, not just a card's base PASSIVE
  value.
- `cn_army`/`cn_royale_army` — `evasionPct` added to the unit snapshot.
  **Not** added to the first, already-at-the-limit `jsonb_build_object(...)`
  call (that throws "cannot pass more than 100 arguments to a function" —
  the exact 0037 regression the code comment above it warns about, and the
  first mistake made while writing this migration); added to the second,
  smaller object that gets concatenated with `||` instead, the same trick
  already used for `swamps`.
- **`cn_attack`: the actual dodge.** A brand-new `v_evaded boolean` is
  rolled once, on the defender, via `cn_chance(v_tgt->>'evasionPct',
  'evasion')` — same generic roll-helper every other percentage in the
  game uses, so `cn.force_evasion` ('always'/'never') is real test-harness
  determinism for free, with zero changes to `cn_chance` itself. The roll
  happens **before** the Quick Dagger pre-check and **before** the
  swing/parry/crit/twice-strike `while` loop — evasion is not a per-swing
  zero-out like Eva's Mist cloud (`cn_mist_dodge`, rogue-only, still zeroes
  one swing but lets the chain continue); it is a single roll that, when it
  lands, skips the *entire* exchange: the Quick Dagger `if` and the chain
  `while` are both gated on `not v_evaded` (a boolean prepend on their
  existing conditions, not a re-indent of the surrounding `else` branch),
  and a third branch was added to the existing two-way `v_note` block so an
  evaded exchange is recorded honestly. A dodged swing lands in
  `state.fx.swings` as one entry, `dmg:0, why:'evade'` — zero damage, zero
  counter, zero chain continuation, distinguishable from an ordinary miss.
  `evasion_pct >= 100` is a certainty (`cn_chance`'s own `>=100`
  short-circuit, already relied on by parry/crit), so the deterministic
  test proving all of this needed no `cn.force_evasion` at all.
- `cn_effect_condition_met` — a new branch mirroring the existing
  `self.hp_pct`/`target.hp_pct` branch, but reading `self.hp`/`target.hp`
  as the **flat** value with no `/maxHp` normalization. Both are now live,
  independent condition fields — `self.hp < 20` and `self.hp_pct < 50` mean
  different things and can both be authored on the same card.

### Client: `AdminCards.tsx` / `AdminStructures.tsx` / `SentenceBuilder.tsx`

Every vocabulary category the builder offers — triggers, targets, actions,
statuses, stat_names, condition fields, durations, and (Cards only) ranges
— now carries a `*_LABELS` map and a `*Label(x) => LABELS[x] ?? x` lookup,
wired into `SentenceVocab` and read by `SentenceBuilder`'s `Pill` calls.
The underlying value saved to `card_effects`/`structure_effects` is
unchanged — a pill still writes `MODIFY_STAT`, `self.hp_pct`,
`CARD_RANGE` — only the *displayed* text changed, e.g. `MODIFY_STAT` →
"modifies stat of", `DEAL_DAMAGE` → "deals damage to", `APPLY_STATUS` →
"applies status", `SELF` → "this card", `self.hp_pct` → "this card's HP
%", `CARD_RANGE` → "in card range", `THIS_TURN` → "this turn", and so on
across all ~90 constants in both files. Non-obvious stat_name labels
(`SWAMPS`, `SNEAKS`, `BLOOMS`, `PARRIES`, `CURES_BURN`, …) were sourced
from the actual mechanics documented in `lib/rules.ts`/`lib/swamp.ts`/
`lib/types.ts` rather than guessed from the constant name. `AdminStructures.tsx`
keeps its own copy of every label map rather than importing `AdminCards.tsx`'s
— the same duplication pattern every other vocabulary constant in that file
already follows — and, per the scope decision above, **keeps SLIPPERY and
FLIES labelled** in its own `STAT_NAME_LABELS`: for a structure they mean
something functionally different (temporarily patching a *unit's* runtime
snapshot via `cn_effect_apply_action`, not a structure's own column), so
removing a unit's own ability from the Structures builder — which was never
the ask — would have been out of scope.

- **`CONDITION_FIELDS`** (both files) gains `self.hp` / `target.hp`
  alongside the existing `self.hp_pct` / `target.hp_pct` — the flat-value
  and percentage-value options Jared asked for, side by side, so a card's
  author can soft-code either style.
- **`FLAGS`** (`AdminCards.tsx`) drops `flies` entirely. This is a
  zero-risk removal: `cn_check_card`'s trigger already unconditionally
  overwrites `new.flies := (new.role = 'flying')` on every save, so the
  checkbox has never actually controlled anything since that trigger was
  added — confirmed no `card_effects` row anywhere uses `FLIES` as a
  `stat_name` either. `flies` stays in the `cards` table and
  `card_effects_stat_name_check` (backward compat only); it is simply gone
  from what the UI offers.
- **`STAT_NAMES`** (`AdminCards.tsx`) drops `SLIPPERY`, adds
  `EVASION_PCT`. Slippery — parry-adjacent evasion tucked inside a stat
  dropdown — is gone from the Cards builder's offered list; the schema
  keeps it (Himanta's card, `cn_attack`'s four read-sites) exactly as
  above.
- **Tab adjacency**: checked, not changed. "Stats" and "Abilities &
  Passives" are already two buttons in the same flex `.admintabs`
  container with a 6px gap and nothing between them — `AdminPanel.tsx`
  has no separate top-level Stats/Abilities tabs either. No code change
  was needed for this item.
- **`AdminStructures.tsx`** gets the full label pass too: `TRIGGER_LABELS`,
  `TARGET_LABELS`, widened `ACTION_LABELS`, new `STATUS_LABELS`,
  `STAT_NAME_LABELS`, `CONDITION_FIELD_LABELS`, and `DURATION_LABELS`, all
  wired onto `STRUCTURE_VOCAB`. `STAT_NAMES` also gains `EVASION_PCT` here
  — a structure can grant it temporarily through the same
  `cn_effect_apply_action` door it already uses for `TWICE_PCT`/
  `REGEN_PCT`, so offering it needed no engine change, only the option.
  `npx tsc -b` is clean across both admin files.

### The same pre-existing `cn_attack` bug, now seen a third place

Section 12 already flagged `column reference "u" is ambiguous` inside
`cn_attack`'s win-condition/achievement query (`u` the correlation name in
`jsonb_array_elements(v_out) u` colliding with `cn_attack`'s own
block-level `u jsonb;` loop variable), reproduced there in `09_combat.sql`
and `12_clock.sql`. Running the full `01`–`33` suite end to end for this
migration (not just the new `33_evasion_and_conditions.sql` in isolation)
turned up the identical error a third time, in `29_allies_and_flight.sql`
(a friendly-fire stun ending a match via a single-class-team win — the
same achievement-check query, a different route into it). **Reproduced
again against migrations 0001-0058 with 0059 removed entirely, same file
and line** — confirming once more that `EVASION_PCT` and this migration's
other `cn_attack` edits are not the cause. Still not fixed here, for the
same reason section 12 gave: not the place to fix the single riskiest
function in the codebase, unasked.

### Tests: `33_evasion_and_conditions.sql`

`EVASION_PCT` accepted as a `stat_name` and actually compiled by
`cn_compile_card_effects` (not merely saveable); `SLIPPERY`/`FLIES` still
insert cleanly (backward compat); `cards_evasion_pct_check` bounds;
a `evasionPct=100` runtime match proving a dodge is one swing (no
counter, no chain), recorded `dmg:0, why:'evade'`, zero damage taken —
deterministic via `cn_chance`'s own `>=100` shortcut, no
`cn.force_evasion` needed; a `evasionPct=0` regression check that ordinary
combat is unaffected; and direct `cn_effect_condition_met` calls proving
`self.hp`/`target.hp` read the flat value while `self.hp_pct`/
`target.hp_pct` keep reading the percentage, unchanged. All green,
idempotent on rerun, and the whole 0001-0059 chain rebuilds cleanly from
`./reset.sh`.

**Addendum (2026-09-17):** `AURA_BONUS_*`/`AURA_RESIST_*` labels in `AdminCards.tsx` now say which way the damage goes, not just "bonus"/"resistance" — confirmed against `cn_aura_bonus`/`cn_aura_resist`: bonus is outgoing (your team's damage *to* that class), resist is incoming (your team's damage *from* that class); `AURA_RESIST_EFFECTS` reduces burn/poison tick damage specifically, not "status effects" broadly. No new stat options added — every other class/status/target already offered here is backed by the engine; inventing a new one (e.g. an "all classes" aura) would need real `cn_aura` changes, not just a label.

## 14. A name color, everywhere a name shows (`0060_name_color.sql`, 2026-09-17)

Jared's ask: let a player pick a color for their own username in Profile,
and have it show wherever anyone else sees that name -- a live match, the
ladder, "anywhere else." Nine fixed swatches, his own list: red, orange,
green, sky blue, (normal) blue, purple, black, gray, brown.

### One column is the truth

`profiles.name_color text not null default 'blue'`, checked against the
nine (`profiles_name_color_check`), plus `set_name_color(p_color)` (mirrors
`set_username`'s shape: `security definer`, validates, updates the caller's
own row). No trigger the way `avatar` needed `cn_check_avatar` -- a color
is either one of the nine or the CHECK itself refuses it, on *every* write
path, including the direct "own profile updatable" RLS route a client
already has. `public.leaderboard` is widened the same way `avatar` and
`tournaments` widened it before (drop/recreate).

Every screen that already reads a live `profiles`/`leaderboard` row --
ladder, friends, admin, your own "who am I" in the corner -- gets the color
for free from that one column. No other server change was needed for those.

### The two places that don't read `profiles` live

- **`match_messages`/`royale_messages`**: these already denormalize
  `username` onto the message row at send time, specifically so a realtime
  `INSERT` payload (which never carries a join) still has a name.
  `name_color` rides along the same column-not-join way, for the same
  reason -- `useMessages`/`useRoyaleMessages` merge `payload.new` directly,
  so a join here would color the first page load and leave every message
  that arrives afterward blank. `match_messages` is inserted straight from
  `Chat.tsx` (already sends `username` itself the same way); `royale_messages`
  goes through `send_royale_message`, which is the one function this
  migration actually splices (it already looked up the sender's `username`
  server-side; now it looks up `name_color` alongside it).
- **`royale_players`**: the opposite case -- its own realtime handler
  (`useRoyalePlayers`) re-runs the *whole* `select` on every change rather
  than merging a bare payload, so a live join never goes stale here. No new
  column: `useRoyaleMatch.ts`'s query becomes
  `select('*, profiles(name_color)')`, flattened onto each row client-side.
- **`matches.host_name`/`guest_name`**: frozen snapshots, same as always --
  but `name_color` is deliberately NOT a third frozen column beside them.
  `getMatchIntroProfiles` (0045) already fetches extra *live* profile data
  by `host_id`/`guest_id` for `VsIntro.tsx` (avatar, featured achievements);
  `name_color` was added to that same call and threaded into `Match.tsx`'s
  `Nameplate` too, which had no such plumbing before this. The payoff:
  since it isn't frozen, a color picked mid-match shows before that match
  ends, unlike `username` itself.

### Client

- `src/lib/nameColors.ts` (new) -- the nine keys, and `nameColorStyle()`,
  which turns a stored key into `{ color: 'var(--nc-<key>)' }` or
  `undefined` for anything it doesn't recognise (a future color an older
  build hasn't shipped a swatch for yet shows as whatever color the text
  already was, never a crash).
- `styles.css` -- nine `--nc-*` custom properties, light and dark. `black`
  and `gray` simply point at the theme's own `--ink`/`--muted` (already
  tuned for both papers); `blue`/`green`/`purple` point at the three
  existing "type-safe" inks this file already had for exactly this problem
  (`--you-ink`/`--good-ink`/`--kw` -- see their own comments on why a raw
  brand/surface color fails as small text on a dark paper). `red`/`orange`/
  `sky`/`brown` are new pairs, lightened for the dark paper the same
  qualitative way those three already are.
- `ProfileCard.tsx` -- a row of nine round swatches under a new "Name
  color" heading (`profile.pickColor`, en+es), same optimistic-update shape
  as the avatar picker (`onChanged` first, `setNameColor` after, rolled
  back on error).
- Rendered with `nameColorStyle()` at every plain-text name span found:
  `Lobby.tsx` (your own name, the ladder table), `Friends.tsx` (list +
  search), `AdminUsers.tsx`, `RoyaleLobby.tsx` (both seat lists),
  `RoyaleMatch.tsx`'s header seat list, `Chat.tsx`/`RoyaleChat.tsx`, and
  `VsIntro.tsx`'s two fighters. `Match.tsx`'s `Nameplate` gets it too, with
  one deliberate exception: the color is dropped (`style={active ?
  undefined : ...}`) while a nameplate is in its "whose turn" state, since
  that state already sets `color: #fff` on a colored pill background for
  contrast (`.nameplate.host.active`/`.guest.active`) and an arbitrary
  player color must not fight that.
- **Left alone, on purpose**: tournament brackets (`TourneyEntry`/
  `TourneySlot` freeze names the same way `matches` does, but nothing here
  confirmed a `user_id` is available at render time the way `host_id`/
  `guest_id` are, so this wasn't extended there without checking first);
  and names interpolated into a translated sentence (`t('royale.winnerIs',
  { name })`, friend-request notification text) -- coloring a name *inside*
  a string would mean splitting every such i18n key into parts, in both
  languages, which is a much bigger change than this one asked for.

### Tests: `34_name_color.sql`

The RPC (accepts one of nine, refused otherwise, by both the RPC's own
check and the CHECK constraint on a direct write); the default ('blue') a
brand-new profile gets; the widened `leaderboard` view; `match_messages`
carrying whatever color the client sends (and refusing a tenth); and
`send_royale_message` looking up the sender's own color and writing it.
All green. **Full `01`-`34` regression sweep, not just this file**: found a
considerably larger set of pre-existing, unrelated stale-test failures than
previously reported here -- `01_rules.sql`/`14_ability_es.sql`/
`23_ghosts.sql`/`25_effects.sql` all assert an old roster count (11) the
roster outgrew (it's 20 today; `25_effects.sql`'s own title says
"twenty units," so this was known and simply never reconciled with
`01_rules.sql`'s "eleven"), `05_idle.sql`/`15_kingdoms.sql`/`16_admin.sql`/
`24_abilities.sql` fail on unrelated assertions, and `09_combat.sql`/
`12_clock.sql`/`29_allies_and_flight.sql` hit the `cn_attack` ambiguous-`u`
bug section 12 already flagged. **Every one of these reproduces identically
with migration 0060 removed entirely**, confirmed by rebuilding from a
tarball of the pre-0060 migration set and rerunning the same sweep -- none
of them are caused by this change. The earlier, smaller list of "known
gaps" in this file undersold how many of these exist; a prior sweep only
looked at the tail of a very long combined log and missed the ones near
the top. Still not fixed here -- same reasoning as always, this migration
is not the place to start clearing a pre-existing backlog it didn't create
-- but the fuller, honest count belongs here rather than staying hidden in
a truncated terminal scroll-back.

## 15. The real deployment gap: migrations 0055-0060 were never applied to the live project (2026-09-17)

Jared hit this directly: the card builder threw `Could not find the
'duration_kind' column of 'card_effects' in the schema cache`, and the new
name-color picker threw `Could not find the function
public.set_name_color(p_color) in the schema cache`. Both errors are
PostgREST's exact wording for "this genuinely does not exist in the
database I introspected" -- not a stale-cache fluke.

**Root cause**: every migration from `0055_delete_active_cards.sql` through
`0060_name_color.sql`, across this session and at least one before it, was
written and validated only against a disposable local scratch Postgres
instance, then delivered as a `.sql` file into this repo's
`supabase/migrations/`. Writing the file and testing it locally was never
the same thing as running it against the actual Supabase project this app
talks to (`dnhvfajvfhmqpbwfvyfq`, "tactica") -- and that last step was
missed, silently, for six migrations in a row. `list_migrations` on the
real project showed it stalled at roughly `0053`/`royale_deploy_fog`; every
feature built on top of that gap (ability sentences, structures, parry
vocabulary, evasion, the human-readable labels, name colors) was fully
correct in the repo and in the scratch DB, and simply not live.

**Fix**: applied `0055` through `0060` to the real project directly, in
strict order, verbatim from the already-tested repo files (via Supabase's
migration tool against the live project, not the scratch DB), watching for
an error at each step. All six applied cleanly. Verified independently
afterward against the real database itself, not by trusting a success flag:
`card_effects.duration_kind`/`group_id`/`range_kind`/`structure_slug` and
the rest all exist and are queryable; `structures`/`structure_effects`/
`card_ability_meta` all exist; `cards.evasion_pct` and its check constraint
exist; the parry vocabulary's constraint/trigger/action additions are all
in place; `profiles.name_color`/`match_messages.name_color`/
`royale_messages.name_color` exist; and `public.set_name_color(text)` now
resolves. Also ran a schema-cache reload (`NOTIFY pgrst, 'reload schema'`)
so the running app would not have to wait on PostgREST's own refresh
interval. Re-tested both exact reported symptoms directly against the real
database afterward and confirmed both are gone.

**Going forward**: any migration written in this project from now on needs
an explicit, separate "applied to the real `dnhvfajvfhmqpbwfvyfq` project"
step, checked the same deliberate way `list_migrations`/`execute_sql`
checked it here -- not assumed from a scratch-DB pass or from the file
existing in the repo.
