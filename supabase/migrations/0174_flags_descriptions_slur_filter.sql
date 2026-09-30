-- 0174: profile flags + descriptions, the slur filter, and card-usage stats.
--
-- Four things, one migration, because the first three all hang off the same
-- table (`profiles`) and the ladder view that reads it.
--
-- 1. `profiles.country` -- an ISO 3166-1 alpha-2 code ('ES', 'US'...) or NULL.
--    The flag itself is an emoji built from the code on the client, so no
--    image files exist and nothing here needs to know what a flag looks like.
--    `leaderboard` gets the column (appended LAST: create-or-replace view may
--    only add columns at the end), which is what lets the Ladder filter by
--    country and draw a flag column. Format is CHECKed; whether the code is a
--    country the picker offers is a client matter.
--
-- 2. `profiles.description` -- up to 100 words, shown on your profile and on
--    anyone else's card. Whitespace is collapsed to single spaces on save.
--
-- 3. The slur filter. `cn_slur_check(text)` is the server's copy of the check
--    in src/lib/profanity.ts -- SAME lists, SAME steps, and the two were
--    compared on a test corpus (81 strings, zero disagreements). It is
--    enforced by a TRIGGER on profiles, not just in the RPCs, on purpose: the
--    "own profile updatable" RLS policy lets a signed-in player UPDATE their
--    own row directly, so a check that lived only in set_username() could be
--    walked around with one PostgREST call. The trigger only looks at a value
--    that is actually CHANGING, so an account whose name predates the filter
--    can still have wins/losses updated. The signup trigger
--    (handle_new_user) is spliced so a slur typed at signup becomes plain
--    'player' rather than a cryptic "database error saving new user".
--
-- 4. `admin_card_usage(p_user)` -- how often each card was fielded, in the
--    last 24h / 7d / 30d / ever, for one player or everybody. Read off
--    match_deploy / royale_deploy (the army each human brought), so bots,
--    simulations and unfinished matches are left out.

-- ---------------------------------------------------------------------------
-- 1 + 2. the columns
-- ---------------------------------------------------------------------------
alter table public.profiles add column if not exists country text;
alter table public.profiles add column if not exists description text;
alter table public.profiles drop constraint if exists profiles_country_shape;
alter table public.profiles add constraint profiles_country_shape
  check (country is null or country ~ '^[A-Z]{2}$');

create or replace function public.set_country(p_country text)
returns text language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v text := nullif(upper(btrim(coalesce(p_country, ''))), '');
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  if v is not null and v !~ '^[A-Z]{2}$' then raise exception 'not a country code'; end if;
  update public.profiles set country = v where id = v_uid;
  return v;
end $$;
revoke execute on function public.set_country(text) from public, anon;
grant execute on function public.set_country(text) to authenticated;

create or replace function public.set_description(p_text text)
returns text language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v text := nullif(btrim(regexp_replace(coalesce(p_text, ''), '\s+', ' ', 'g')), '');
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  -- the slur check and the 100-word limit are the trigger's job (below), so
  -- they hold for a direct UPDATE too.
  update public.profiles set description = v where id = v_uid;
  return v;
end $$;
revoke execute on function public.set_description(text) from public, anon;
grant execute on function public.set_description(text) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. the slur filter
-- ---------------------------------------------------------------------------
create or replace function public.cn_slur_check(p_text text)
returns boolean language plpgsql immutable set search_path = public as $fn$
declare
  a text[] := array['nigger', 'nigga', 'niggah', 'niggaz', 'niglet', 'faggot', 'faggit', 'faggy', 'fagot', 'fuck', 'fvck', 'phuck', 'fuq', 'shit', 'bitch', 'bastard', 'asshole', 'arsehole', 'dumbass', 'jackass', 'fatass', 'asswipe', 'cunt', 'penis', 'vagina', 'dildo', 'blowjob', 'handjob', 'rimjob', 'cumshot', 'pussy', 'whore', 'slutty', 'wanker', 'bollocks', 'bollock', 'dickhead', 'cocksucker', 'douche', 'molest', 'pedophile', 'paedophile', 'pedophilia', 'paedophilia', 'pedobear', 'jizz', 'orgasm', 'masturbate', 'masturbation', 'clitoris', 'butthole', 'sexting', 'porn', 'hentai', 'onlyfans', 'hitler', 'neonazi', 'swastika', 'kkk', 'beaner', 'wetback', 'jigaboo', 'porchmonkey', 'towelhead', 'raghead', 'tranny', 'trannie', 'shemale', 'sodomite', 'mongoloid', 'gilipollas', 'hijueputa', 'hijoputa', 'putain', 'connard', 'connasse', 'salope', 'encule', 'bougnoule', 'youpin', 'arschloch', 'hurensohn', 'wichser', 'schlampe', 'missgeburt', 'scheisse', 'scheiss', 'cazzo', 'stronzo', 'puttana', 'vaffanculo', 'minchia', 'coglione', 'caralho', 'buceta', 'arrombado', 'filhodaputa', 'pizda', 'orospu', 'mierda', 'bullshit'];
  b text[] := array['ass', 'asses', 'arse', 'arses', 'dick', 'dicks', 'cock', 'cocks', 'twat', 'prick', 'sex', 'sexy', 'tits', 'boob', 'boobs', 'boobies', 'nipple', 'clit', 'vulva', 'anus', 'anal', 'cum', 'semen', 'boner', 'horny', 'fap', 'fapping', 'wank', 'wanking', 'slut', 'sluts', 'rape', 'raped', 'raping', 'rapes', 'rapist', 'rapists', 'pedo', 'nazi', 'nazis', 'chink', 'chinks', 'kike', 'kyke', 'spic', 'spick', 'gook', 'coon', 'coons', 'paki', 'jap', 'japs', 'wop', 'dago', 'tranny', 'fag', 'fags', 'faggots', 'dyke', 'lesbo', 'retard', 'retards', 'retarded', 'retardo', 'spaz', 'spastic', 'tard', 'autist', 'sperg', 'mong', 'kys', 'milf', 'hoe', 'hoes', 'cuck', 'nudes', 'puta', 'puto', 'putas', 'putos', 'pendejo', 'pendeja', 'pendejos', 'cabron', 'cabrona', 'joder', 'verga', 'chingada', 'chingar', 'chinga', 'chingado', 'culero', 'zorra', 'maricon', 'marica', 'maricones', 'capullo', 'hdp', 'ctm', 'merde', 'batard', 'nique', 'niquer', 'ntm', 'fdp', 'pute', 'negre', 'neger', 'kanake', 'spast', 'nutte', 'fick', 'ficken', 'ficker', 'fickt', 'arsch', 'fotze', 'merda', 'troia', 'frocio', 'porra', 'viado', 'cuzao', 'blyat', 'blyad', 'cyka', 'pidor', 'pidar', 'pidr', 'huy', 'ebat', 'mudak', 'amk', 'polack'];
  c text[] := array['nigger', 'nigga', 'faggot', 'fuck', 'whitepower', 'whitepride', 'killyourself', 'killurself', 'gasthejews', 'heilhitler', 'siegheil'];
  allow text[] := array['scunthorpe', 'penistone'];
  s text; t text; toks text[]; words text[]; run text; tok text; w text; compact text;
  v int;
begin
  if p_text is null or btrim(p_text) = '' then return false; end if;
  s := regexp_replace(p_text, '([a-z])([A-Z])', '\1 \2', 'g');
  s := regexp_replace(s, '([A-Z])([A-Z][a-z])', '\1 \2', 'g');
  s := translate(lower(s), 'áàäâãåéèëêíìïîóòöôõøúùüûñçýÿ', 'aaaaaaeeeeiiiioooooouuuuncyy');
  for v in 0..1 loop
    t := s;
    if v = 1 then t := translate(t, '013457@$!', 'oieastasi'); end if;
    t := btrim(regexp_replace(t, '[^a-z]+', ' ', 'g'));
    if t = '' then continue; end if;
    toks := string_to_array(t, ' ');
    words := '{}'; run := '';
    foreach tok in array toks loop
      if char_length(tok) = 1 then
        run := run || tok;
      else
        if char_length(run) >= 3 then words := words || run; end if;
        run := '';
        words := words || tok;
      end if;
    end loop;
    if char_length(run) >= 3 then words := words || run; end if;
    foreach tok in array words loop
      foreach w in array allow loop tok := replace(tok, w, ''); end loop;
      foreach w in array a loop
        if position(w in tok) > 0 then return true; end if;
      end loop;
      if tok = any(b) then return true; end if;
      if right(tok, 1) = 's' and left(tok, -1) = any(b) then return true; end if;
    end loop;
    compact := array_to_string(toks, '');
    foreach w in array c loop
      if position(w in compact) > 0 then return true; end if;
    end loop;
  end loop;
  return false;
end $fn$;

create or replace function public.cn_check_profile_text()
returns trigger language plpgsql set search_path = public as $$
begin
  if tg_op = 'INSERT' or new.username is distinct from old.username then
    if public.cn_slur_check(new.username) then
      raise exception 'the username can''t contain slurs';
    end if;
  end if;
  if new.description is not null
     and (tg_op = 'INSERT' or new.description is distinct from old.description) then
    if public.cn_slur_check(new.description) then
      raise exception 'the description can''t contain slurs';
    end if;
    if coalesce(array_length(regexp_split_to_array(btrim(new.description), '\s+'), 1), 0) > 100 then
      raise exception 'a description is at most 100 words';
    end if;
    if char_length(new.description) > 900 then
      raise exception 'that description is too long';
    end if;
  end if;
  return new;
end $$;

drop trigger if exists profiles_text_is_clean on public.profiles;
create trigger profiles_text_is_clean
  before insert or update of username, description on public.profiles
  for each row execute function public.cn_check_profile_text();

-- Signup: a slur typed as the display name becomes 'player' (then player1...
-- via the existing uniqueness loop). A text splice over the LIVE definition,
-- with the anchor asserted to occur exactly once; a re-run is a no-op.
do $splice$
declare
  d text := pg_get_functiondef('public.handle_new_user()'::regprocedure);
  anchor text := 'if char_length(base) < 2 then';
begin
  if position('cn_slur_check' in d) > 0 then return; end if;
  if (char_length(d) - char_length(replace(d, anchor, ''))) / char_length(anchor) <> 1 then
    raise exception 'handle_new_user: splice anchor not found exactly once';
  end if;
  execute replace(d, anchor, 'if char_length(base) < 2 or public.cn_slur_check(base) then');
end $splice$;

-- ---------------------------------------------------------------------------
-- the ladder gets the flag column (appended last)
-- ---------------------------------------------------------------------------
create or replace view public.leaderboard as
  select p.id, p.username, p.avatar, p.name_color,
         coalesce(r.rating, 1000) as rating,
         p.wins, p.losses, p.games, p.streak, p.tournaments,
         p.country
    from public.profiles p
    left join public.player_rating r on r.user_id = p.id
   where not p.is_system;

-- ---------------------------------------------------------------------------
-- 4. card usage
-- ---------------------------------------------------------------------------
create or replace function public.admin_card_usage(p_user uuid default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v jsonb;
begin
  if not cn_is_super_admin() then raise exception 'admin only'; end if;
  with used as (
    select e->>'slug' as slug, m.updated_at as at
      from public.match_deploy d
      join public.matches m on m.id = d.match_id
      cross join lateral jsonb_array_elements(d.units) e
     where m.status = 'finished' and not m.is_sim and d.user_id is not null
       and (p_user is null or d.user_id = p_user)
    union all
    select e->>'slug', rm.updated_at
      from public.royale_deploy d
      join public.royale_matches rm on rm.id = d.match_id
      cross join lateral jsonb_array_elements(d.units) e
     where rm.status = 'finished' and d.user_id is not null
       and (p_user is null or d.user_id = p_user)
  ), agg as (
    select slug,
           count(*) filter (where at >= now() - interval '1 day')  as d1,
           count(*) filter (where at >= now() - interval '7 days')  as d7,
           count(*) filter (where at >= now() - interval '30 days') as d30,
           count(*) as dall
      from used where slug is not null group by slug
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'slug', a.slug, 'name', coalesce(c.name, a.slug),
           'day', a.d1, 'week', a.d7, 'month', a.d30, 'all', a.dall)
         order by a.dall desc, a.slug), '[]'::jsonb)
    into v
    from agg a left join public.cards c on c.slug = a.slug;
  return v;
end $$;
revoke execute on function public.admin_card_usage(uuid) from public, anon;
grant execute on function public.admin_card_usage(uuid) to authenticated;
