-- 0234 -- IMMUNE_<CLASS> stats: Nara, "Immune to Kings' and Queens' attacks".
-- A PASSIVE / SELF / MODIFY_STAT row with stat_name IMMUNE_ROYAL (or _KNIGHT,
-- _ROGUE, _MAGE, _FLYING) makes the unit take no damage from a blow struck by
-- a unit of that class -- first blows and counters alike (a counter is a
-- blow); effects, burn and poison are not "attacks" and are unchanged.
-- Read straight off the unit's own abilityScript (cn_unit_from_card already
-- copies every card_effects row onto it), so nothing is compiled or hard-coded
-- per card.  The immune blow lands as 0 (no crit), like a dodged one.
-- Also applied to DEAL_ATTACK_PCT, which is an attack's damage by another route.

alter table public.card_effects drop constraint if exists card_effects_stat_name_check;
alter table public.card_effects add constraint card_effects_stat_name_check check (stat_name is null or stat_name = any (array[
  'SLIPPERY','TWICE_PCT','LIFESTEAL_PCT','PARRY_ALL','REGEN_PCT','STUNS_ON_HIT','POISONS_ADJACENT','VS_POISONED_BONUS',
  'CURES_BURN','BLOOMS','SNEAKS','FLIES','TRAMPLES','PARRIES','BURNS','HEALS','SWAMPS',
  'AURA_RESIST_KNIGHT','AURA_RESIST_ROGUE','AURA_RESIST_MAGE','AURA_RESIST_FLYING',
  'AURA_BONUS_KNIGHT','AURA_BONUS_ROGUE','AURA_BONUS_MAGE','AURA_BONUS_FLYING','AURA_RESIST_EFFECTS',
  'HP','MOV','RMIN','RMAX','CRMIN','CRMAX','POWER','PARRY_PCT','CRIT_PCT','EVASION_PCT',
  'IMMUNE_ROYAL','IMMUNE_KNIGHT','IMMUNE_ROGUE','IMMUNE_MAGE','IMMUNE_FLYING'
]::text[]));

create or replace function public.cn_immune(p_recv jsonb, p_strk jsonb)
returns boolean language sql stable set search_path to 'public' as $$
  select case when jsonb_typeof(p_recv->'abilityScript') = 'array' then exists (
    select 1 from jsonb_array_elements(p_recv->'abilityScript') r
     where r->>'trigger' = 'PASSIVE' and r->>'action' = 'MODIFY_STAT'
       and r->>'stat_name' = 'IMMUNE_' || upper(coalesce(p_strk->>'role', ''))
       and coalesce((r->>'value')::numeric, 1) <> 0)
  else false end
$$;

do $mig$
declare v_def text; v_new text; v_fn text;
begin
  foreach v_fn in array array['public.cn_attack(uuid,text,text,text)', 'public.cn_attack_royale(uuid,integer,text,text)'] loop
    v_def := pg_get_functiondef(v_fn::regprocedure);
    v_new := replace(v_def, '      if v_missed then v_hit := 0; v_hit_crit := false; end if;',
      '      if v_missed then v_hit := 0; v_hit_crit := false; end if;' || chr(10) ||
      '      if cn_immune(v_recv, v_strk) then v_hit := 0; v_hit_crit := false; end if;');
    if v_new = v_def then raise exception '% was not changed', v_fn; end if;
    execute v_new;
  end loop;

  v_def := pg_get_functiondef('public.cn_effect_apply_action(jsonb,jsonb,jsonb,text,jsonb)'::regprocedure);
  v_new := replace(v_def, '      u := jsonb_set(u, ''{hp}'', to_jsonb((u->>''hp'')::int - cn_damage(
        greatest(0,',
'      u := jsonb_set(u, ''{hp}'', to_jsonb((u->>''hp'')::int - case when cn_immune(u, p_unit) then 0 else cn_damage(
        greatest(0,');
  v_new := replace(v_new, '        coalesce((u->>''defending'')::boolean, false))));

    elsif u->>''id'' = p_target_id and v_action = ''GRANT_EXTRA_ATTACK'' then',
'        coalesce((u->>''defending'')::boolean, false)) end));

    elsif u->>''id'' = p_target_id and v_action = ''GRANT_EXTRA_ATTACK'' then');
  if v_new = v_def or position('case when cn_immune' in v_new) = 0 or position('false)) end));' in v_new) = 0 then
    raise exception 'DEAL_ATTACK_PCT branch not changed';
  end if;
  execute v_new;
end $mig$;
