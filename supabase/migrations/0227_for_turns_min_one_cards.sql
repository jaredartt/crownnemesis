-- "Fire once" for a card's sentence: FOR_TURNS counts how many times the row may
-- fire, and 1 is a legitimate answer (King Dereo's team crit buff). Cards only;
-- structure_effects keeps 2..5.
alter table public.card_effects drop constraint if exists card_effects_duration_turns_check;
alter table public.card_effects add constraint card_effects_duration_turns_check
  check (duration_turns is null or duration_turns between 1 and 20);
