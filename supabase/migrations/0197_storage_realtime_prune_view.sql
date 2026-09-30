-- !!! NOT APPLIED to the live database yet -- waiting on Jared (see project_status 77aa). !!!
-- 0197: security review follow-up, part 2.
--   * storage bucket size / type limits (they were unlimited; only admins can write)
--   * Realtime: stop publishing tables the client never subscribes to
--   * a daily cleanup so spam/old rows can't grow the database forever
--   * the leaderboard view runs as the person asking, not as its owner

-- ---- storage ---------------------------------------------------------------
update storage.buckets set file_size_limit = 6 * 1024 * 1024,
  allowed_mime_types = array['image/jpeg','image/png','image/webp','image/gif','image/avif','image/svg+xml']
  where id = 'art';
update storage.buckets set file_size_limit = 30 * 1024 * 1024,
  allowed_mime_types = array['audio/mpeg','audio/mp3','audio/ogg','application/ogg','audio/wav','audio/x-wav',
                             'audio/webm','audio/mp4','audio/aac','audio/flac','audio/x-m4a']
  where id = 'audio';
update storage.buckets set file_size_limit = 10 * 1024 * 1024,
  allowed_mime_types = array['image/jpeg','image/png','image/webp','image/gif','image/avif']
  where id = 'comics';

-- ---- Realtime ---------------------------------------------------------------
-- The tournament screen polls; friends' online dots now poll every 30s instead
-- of listening to every heartbeat from every player (see useFriends.ts).
alter publication supabase_realtime drop table public.tournaments;
alter publication supabase_realtime drop table public.tournament_entries;
alter publication supabase_realtime drop table public.tournament_matches;
alter publication supabase_realtime drop table public.user_presence;

-- ---- daily cleanup ------------------------------------------------------------
create or replace function public.cn_prune_old_data() returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare n integer; o jsonb := '{}'::jsonb;
begin
  delete from public.royale_engine_log where at < now() - interval '7 days';
  get diagnostics n = row_count; o := o || jsonb_build_object('engine_log', n);

  delete from public.notifications where created_at < now() - interval '60 days';
  get diagnostics n = row_count; o := o || jsonb_build_object('notifications', n);

  delete from public.match_messages mm using public.matches m
   where mm.match_id = m.id and m.status = 'finished' and m.updated_at < now() - interval '14 days';
  get diagnostics n = row_count; o := o || jsonb_build_object('match_messages', n);

  delete from public.royale_messages rm using public.royale_matches m
   where rm.match_id = m.id and m.status = 'finished' and m.updated_at < now() - interval '14 days';
  get diagnostics n = row_count; o := o || jsonb_build_object('royale_messages', n);

  -- bot-vs-bot training runs, and rooms/matches nobody has touched for 2 days
  delete from public.matches where is_sim and created_at < now() - interval '3 days';
  get diagnostics n = row_count; o := o || jsonb_build_object('sim_matches', n);
  delete from public.matches
   where tournament_match_id is null and status in ('waiting', 'deploying', 'active')
     and updated_at < now() - interval '2 days';
  get diagnostics n = row_count; o := o || jsonb_build_object('stale_matches', n);
  delete from public.matches
   where tournament_match_id is null and status = 'finished' and updated_at < now() - interval '120 days';
  get diagnostics n = row_count; o := o || jsonb_build_object('old_matches', n);

  delete from public.royale_matches
   where status in ('waiting', 'deploying', 'active') and updated_at < now() - interval '2 days';
  get diagnostics n = row_count; o := o || jsonb_build_object('stale_royale', n);

  delete from public.user_presence where seen_at < now() - interval '90 days';
  delete from public.friend_requests where status = 'declined' and updated_at < now() - interval '30 days';
  delete from public.cn_rate where win_start < now() - interval '2 days';
  return o;
end $$;
revoke all on function public.cn_prune_old_data() from public, anon, authenticated;
select cron.schedule('cn-prune', '10 4 * * *', 'select public.cn_prune_old_data()');

-- ---- leaderboard ----------------------------------------------------------------
alter view public.leaderboard set (security_invoker = true);
revoke all on public.leaderboard from anon;
revoke insert, update, delete, truncate, references, trigger on public.leaderboard from authenticated;
