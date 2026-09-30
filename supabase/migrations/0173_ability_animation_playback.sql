-- 0173: live animation playback for scripted abilities -- PHASES 1 + 2 (server).
--
-- project_status.md §75 scoped this; 0158_animations.sql built the catalog and
-- the admin picker and said, in its own header, that a real match "does not
-- play it yet". This migration is the server half of making it play.
--
-- THE GAP (found by reading the LIVE definitions, not migration history):
-- cn_army snapshots each card's card_effects rows onto the unit as
-- `abilityScript` but its jsonb_build_object never included
-- ce.animation_slug, so the chosen animation never survived into a match.
--
-- PHASE 1 -- cn_army: add 'animation_slug' to each abilityScript row.
--   Matches already in progress keep their old snapshot (no slug -> nothing
--   plays), which is exactly right: nothing changes for a game mid-flight.
--
-- PHASE 2 -- get it into fx.
--   cn_run_effects returns only the new state (see 0101's header for why it
--   never grew a side-channel and why that stays true: 8 other trigger call
--   sites would ripple). So the report travels INSIDE the state it already
--   returns, under a scratch key `animQueue`, and ONLY when the caller opts in
--   with p_context.collectAnims = true. Only cn_ability opts in, reads the
--   queue back out, STRIPS the key before the state is saved, and puts it on
--   fx as `fx.anims`:
--       [{ slug, by:{id,x,y}, targets:[{id,x,y}] }, ...]
--   Positions are snapshotted BEFORE the action applies, so a target the
--   sentence kills is still drawn where it stood. A '@x,y' tile target is
--   carried as its own coordinates; a '#deadAlly' target has no tile and is
--   simply not listed. Whether an animation is drawn at the caster, the
--   targets, both sides' units or the whole board is the ANIMATION's own
--   play_at, resolved by the client from this data -- the server only says
--   which sentence fired, from where, onto what.
--
--   The whole collection is wrapped so a cosmetic failure can never fail the
--   ability itself (an exception is swallowed and the entry is simply
--   omitted).
--
-- NOT covered on purpose: legacy hand-built ability kinds (aoe_adjacent,
-- heal_any, ...) have no UI path to an animation_slug; cn_ability_royale never
-- ran scripted sentences; turn_deadline is NOT extended by an animation's
-- duration_ms (0158's header flags that as a follow-up -- combat does it via
-- cn_cine_ms, an ability still only gets cn_cine_ms(v_swings)).
--
-- Applied as a text splice over the live definitions, like 0156/0157, with
-- every anchor asserted to occur exactly once so a drifted definition fails
-- loudly instead of half-patching. Re-running is a no-op.

do $mig$
declare
  v_army text; v_run text; v_abil text;

  -- exactly-once replace; raises when the anchor is missing or repeated
  cnt int;
begin
  v_army := pg_get_functiondef('public.cn_army(jsonb, text, text[])'::regprocedure);
  v_run  := pg_get_functiondef('public.cn_run_effects(jsonb, text, jsonb, jsonb)'::regprocedure);
  v_abil := pg_get_functiondef('public.cn_ability(uuid, text, text, text)'::regprocedure);

  -- ---------------------------------------------------------------- cn_army
  if v_army !~ 'animation_slug' then
    cnt := (length(v_army) - length(replace(v_army, $a$'structure_slug', ce.structure_slug,$a$, ''))) / length($a$'structure_slug', ce.structure_slug,$a$);
    if cnt <> 1 then raise exception '0173 cn_army anchor count=%', cnt; end if;
    v_army := replace(v_army, $a$'structure_slug', ce.structure_slug,$a$,
      $a$'structure_slug', ce.structure_slug,
             'animation_slug', ce.animation_slug,  -- 0173$a$);
    execute v_army;
  end if;

  -- --------------------------------------------------------- cn_run_effects
  if v_run !~ 'animQueue' then
    -- declarations
    cnt := (length(v_run) - length(replace(v_run, $a$v_effect_id text; v_fire_count int; v_for_turns_limit int;$a$, ''))) / length($a$v_effect_id text; v_fire_count int; v_for_turns_limit int;$a$);
    if cnt <> 1 then raise exception '0173 cn_run_effects decl anchor count=%', cnt; end if;
    v_run := replace(v_run, $a$v_effect_id text; v_fire_count int; v_for_turns_limit int;$a$,
      $a$v_effect_id text; v_fire_count int; v_for_turns_limit int;
  -- 0173: opt-in animation report -- see this migration's header.
  v_collect boolean := coalesce(p_context->>'collectAnims', '') = 'true';
  v_anim_targets jsonb := '[]'::jsonb; v_pt jsonb;$a$);

    -- per applied target: snapshot where it stands BEFORE the action lands
    cnt := (length(v_run) - length(replace(v_run, $a$v_st := cn_effect_apply_action(v_st, v_row, v_self_cur, v_tid, v_ctx);$a$, ''))) / length($a$v_st := cn_effect_apply_action(v_st, v_row, v_self_cur, v_tid, v_ctx);$a$);
    if cnt <> 1 then raise exception '0173 cn_run_effects apply anchor count=%', cnt; end if;
    v_run := replace(v_run, $a$v_st := cn_effect_apply_action(v_st, v_row, v_self_cur, v_tid, v_ctx);$a$,
      $a$if v_collect then
        begin
          v_pt := null;
          if left(v_tid, 1) = '@' then
            v_pt := jsonb_build_object('id', v_tid,
              'x', split_part(substr(v_tid, 2), ',', 1)::int,
              'y', split_part(substr(v_tid, 2), ',', 2)::int);
          else
            select jsonb_build_object('id', q->>'id', 'x', (q->>'x')::int, 'y', (q->>'y')::int)
              into v_pt
              from jsonb_array_elements(coalesce(v_st->'units', '[]'::jsonb)) q
             where q->>'id' = v_tid limit 1;
            if v_pt is null then
              select jsonb_build_object('id', q->>'id', 'x', (q->>'x')::int, 'y', (q->>'y')::int)
                into v_pt
                from jsonb_array_elements(coalesce(v_st->'obstacles', '[]'::jsonb)) q
               where q->>'id' = v_tid limit 1;
            end if;
          end if;
          if v_pt is not null then v_anim_targets := v_anim_targets || jsonb_build_array(v_pt); end if;
        exception when others then null;   -- cosmetic only: never fail the ability
        end;
      end if;
      v_st := cn_effect_apply_action(v_st, v_row, v_self_cur, v_tid, v_ctx);$a$);

    -- after the row's targets: queue the report for this sentence
    cnt := (length(v_run) - length(replace(v_run, $a$-- 0147: this row got its turn -- count it once per trigger occurrence,$a$, ''))) / length($a$-- 0147: this row got its turn -- count it once per trigger occurrence,$a$);
    if cnt <> 1 then raise exception '0173 cn_run_effects queue anchor count=%', cnt; end if;
    v_run := replace(v_run, $a$-- 0147: this row got its turn -- count it once per trigger occurrence,$a$,
      $a$-- 0173: this sentence fired -- report which animation, from where, onto what.
    if v_collect and coalesce(v_row->>'animation_slug', '') <> '' then
      begin
        v_st := jsonb_set(v_st, '{animQueue}',
          coalesce(v_st->'animQueue', '[]'::jsonb) || jsonb_build_array(jsonb_build_object(
            'slug', v_row->>'animation_slug',
            'by', jsonb_build_object('id', v_self_cur->>'id',
                                     'x', (v_self_cur->>'x')::int, 'y', (v_self_cur->>'y')::int),
            'targets', v_anim_targets)), true);
      exception when others then null;
      end;
    end if;
    v_anim_targets := '[]'::jsonb;

    -- 0147: this row got its turn -- count it once per trigger occurrence,$a$);
    execute v_run;
  end if;

  -- ------------------------------------------------------------- cn_ability
  if v_abil !~ 'animQueue' then
    cnt := (length(v_abil) - length(replace(v_abil, $a$v_before_units jsonb; v_win text;$a$, ''))) / length($a$v_before_units jsonb; v_win text;$a$);
    if cnt <> 1 then raise exception '0173 cn_ability decl anchor count=%', cnt; end if;
    v_abil := replace(v_abil, $a$v_before_units jsonb; v_win text;$a$,
      $a$v_before_units jsonb; v_win text;
  -- 0173: animations the fired sentences asked for -> fx.anims
  v_anims jsonb := '[]'::jsonb;$a$);

    cnt := (length(v_abil) - length(replace(v_abil, $a$v_st := cn_run_effects(v_st, 'ON_ABILITY', v_me, v_ctx);$a$, ''))) / length($a$v_st := cn_run_effects(v_st, 'ON_ABILITY', v_me, v_ctx);$a$);
    if cnt <> 1 then raise exception '0173 cn_ability run anchor count=%', cnt; end if;
    v_abil := replace(v_abil, $a$v_st := cn_run_effects(v_st, 'ON_ABILITY', v_me, v_ctx);$a$,
      $a$v_ctx := v_ctx || jsonb_build_object('collectAnims', true);
      v_st := cn_run_effects(v_st, 'ON_ABILITY', v_me, v_ctx);
      -- 0173: read the report back out and strip the scratch key so it is
      -- never saved into match state.
      v_anims := coalesce(v_st->'animQueue', '[]'::jsonb);
      v_st := v_st - 'animQueue';$a$);

    cnt := (length(v_abil) - length(replace(v_abil, $a$'cured', false, 'parry', false, 'tree', false), true);$a$, ''))) / length($a$'cured', false, 'parry', false, 'tree', false), true);$a$);
    if cnt <> 1 then raise exception '0173 cn_ability fx anchor count=%', cnt; end if;
    v_abil := replace(v_abil, $a$'cured', false, 'parry', false, 'tree', false), true);$a$,
      $a$'cured', false, 'parry', false, 'tree', false,
    'anims', v_anims), true);  -- 0173$a$);
    execute v_abil;
  end if;

  -- ------------------------------------------------------------- self-check
  if pg_get_functiondef('public.cn_army(jsonb, text, text[])'::regprocedure) !~ 'animation_slug'
     or pg_get_functiondef('public.cn_run_effects(jsonb, text, jsonb, jsonb)'::regprocedure) !~ 'animQueue'
     or pg_get_functiondef('public.cn_ability(uuid, text, text, text)'::regprocedure) !~ 'v_anims' then
    raise exception '0173 self-check failed: a patched definition is missing its marker';
  end if;
end
$mig$;
