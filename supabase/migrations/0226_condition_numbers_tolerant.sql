-- A condition typed as "20%" (or "20 ") used to be stored as that text and then
-- blew up the whole action ('invalid input syntax for type numeric: "20%"').
-- Every numeric comparison in cn_effect_condition_met now reads the number out
-- of the text, so a stray % or space can never fail a move again.
do $$
declare d text;
begin
  d := pg_get_functiondef('public.cn_effect_condition_met(jsonb,jsonb)'::regprocedure);
  d := replace(d, 'nullif(v_val, '''')::numeric',
                  'nullif(regexp_replace(coalesce(v_val, ''''), ''[^0-9.\-]'', '''', ''g''), '''')::numeric');
  execute d;
end $$;
