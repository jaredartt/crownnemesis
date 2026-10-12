-- 0230 -- ON_ALLY_DEATH: "when an ally is defeated", for King Stelaris.
-- Jared: "Heals (+5 HP) all allies when an ally is defeated" -- soft code had
-- the action (HEAL) and the target (ALL_ALLIES) but no trigger: ON_DEATH only
-- ever reads the DYING unit's own script, so Stelaris could never react to a
-- teammate falling.
--
--  * trigger ON_ALLY_DEATH: after a unit's own ON_DEATH, every unit still
--    standing on the same side (same owner) runs its ON_ALLY_DEATH rows, with
--    the fallen unit in the context as `dead` (so a row can ask `dead.role`).
--  * condition field `dead.role` (same shape as self.role / target.role).
--  * the hook lives in cn_run_death(), and cn_attack / cn_attack_royale call it
--    in place of their two direct ON_DEATH cn_run_effects calls (both paths
--    that kill a unit today: the target, and an attacker killed by the counter).

alter table public.card_effects drop constraint if exists card_effects_trigger_check;
alter table public.card_effects add constraint card_effects_trigger_check check (trigger = any (array[
  'ON_PLAY','ON_ABILITY','ON_ATTACK','ON_DEATH','START_OF_TURN','END_OF_TURN','ON_PARRY','PASSIVE',
  'ON_COUNTER','ON_KILL','ON_HEALED','ON_DAMAGED','ON_STATUS_APPLIED','IS_PARRIED','ON_ALLY_DEATH'
]::text[]));

create or replace function public.cn_run_death(v_st jsonb, p_unit jsonb, p_context jsonb)
returns jsonb language plpgsql set search_path to 'public' as $$
declare
  v_ids jsonb := '[]'::jsonb; u jsonb; v_id text; v_cur jsonb;
begin
  v_st := cn_run_effects(v_st, 'ON_DEATH', p_unit, p_context);
  -- Everyone left on the fallen unit's side, snapshotted first: a row may
  -- change the board while we walk it.
  for u in select * from jsonb_array_elements(coalesce(v_st->'units', '[]'::jsonb)) loop
    if u->>'owner' = p_unit->>'owner' and u->>'id' <> p_unit->>'id' and (u->>'hp')::int > 0 then
      v_ids := v_ids || to_jsonb(u->>'id');
    end if;
  end loop;
  for v_id in select * from jsonb_array_elements_text(v_ids) loop
    v_cur := null;
    for u in select * from jsonb_array_elements(coalesce(v_st->'units', '[]'::jsonb)) loop
      if u->>'id' = v_id then v_cur := u; end if;
    end loop;
    continue when v_cur is null or (v_cur->>'hp')::int <= 0;
    v_st := cn_run_effects(v_st, 'ON_ALLY_DEATH', v_cur,
      coalesce(p_context, '{}'::jsonb) || jsonb_build_object('dead', p_unit));
  end loop;
  return v_st;
end $$;

do $mig$
declare v_def text; v_new text; v_fn text;
begin
  foreach v_fn in array array['public.cn_attack', 'public.cn_attack_royale', 'public.cn_effect_condition_met'] loop
    v_def := pg_get_functiondef(v_fn::regproc);
    if v_fn = 'public.cn_effect_condition_met' then
      v_new := replace(v_def, 'v_field in (''self.role'', ''target.role'')', 'v_field in (''self.role'', ''target.role'', ''dead.role'')');
    else
      v_new := replace(v_def, 'cn_run_effects(v_st, ''ON_DEATH'', ', 'cn_run_death(v_st, ');
    end if;
    if v_new = v_def then raise exception '% was not changed', v_fn; end if;
    execute v_new;
  end loop;
end $mig$;
