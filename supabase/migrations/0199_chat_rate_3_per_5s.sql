-- 0199: correction to 0198. Jared: the 4th message inside a 5-second window is
-- the one refused, i.e. 3 messages per 5 seconds.
create or replace function public.cn_trg_chat_rate() returns trigger
language plpgsql security definer set search_path to 'public' as $$
begin
  if auth.uid() is not null and new.user_id = auth.uid() then
    perform public.cn_hit('chat', 3, 5, 'slow down -- wait a few seconds between messages');
  end if;
  return new;
end $$;
