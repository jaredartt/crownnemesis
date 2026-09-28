-- Jared: rename every in-game Spanish occurrence of "Rango" (used for card
-- ability distance) to "Alcance", to match the noun already used
-- everywhere else in the Spanish UI (kingdom.sortRange = "Alcance",
-- stat.rng = "ALC", board.defendNote/attackNoTarget/abilityNoTarget all
-- already say "alcance"). A handful of card/structure ability texts stored
-- in the DB were written before that convention settled and still say
-- "Rango N". General text substitution rather than a per-card hardcode,
-- so any future ability text authored the old way is covered too.
--
-- Excluded on purpose: i18n key tourney.blurb's "Tu rango no está en
-- juego" uses "rango" to mean RANK (ladder standing), not attack range --
-- leaving that one alone.
update public.cards
  set ability_es = replace(ability_es, 'Rango', 'Alcance')
  where ability_es ilike '%Rango%';

update public.structures
  set description_es = replace(description_es, 'Rango', 'Alcance')
  where description_es ilike '%Rango%';
