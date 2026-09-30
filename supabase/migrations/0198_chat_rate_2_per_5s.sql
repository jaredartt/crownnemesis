-- 0198: chat spacing. Jared: "the 3rd message within 5 seconds is refused, so
-- that players space out messaging". Replaces 0196's 8-per-10s limit.
create or replace function public.cn_trg_chat_rate() returns trigger
language plpgsql security definer set search_path to 'public' as $$
begin
  if auth.uid() is not null and new.user_id = auth.uid() then
    perform public.cn_hit('chat', 2, 5, 'slow down -- wait a few seconds between messages');
  end if;
  return new;
end $$;
