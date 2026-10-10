-- =====================================================================
-- LabGram beta features — FULL STRUCTURAL ROLLBACK
-- Restores the schema exactly as it was before 20261010_beta_features.up.sql
-- (verified in staging: fingerprint after up+down == fingerprint before up).
--
-- DATA IMPACT — read before running:
--   * lg_saves is dropped: users' saved-post lists are lost.
--   * lg_comments.parent_id is dropped: replies are KEPT as ordinary comments; only the
--     thread link is lost.
--   * lg_posts.edited_at is dropped: edited TEXT is kept; only the "edited" marker is lost.
--   * lg_notifications.comment_id is dropped: notifications are kept.
-- Prefer the non-destructive rollback (redeploy the previous frontend) unless the schema
-- itself must be removed. Take the backup (20261010_backup.sql) first either way.
-- =====================================================================
begin;

drop table if exists public.lg_saves;

drop policy if exists lg_posts_not_banned_update on public.lg_posts;
drop index if exists public.lg_comments_parent_idx;
alter table public.lg_notifications drop column if exists comment_id;
alter table public.lg_comments drop column if exists parent_id;
alter table public.lg_posts drop column if exists edited_at;

-- previous function bodies (identical to production before the migration)
create or replace function public.lg_guard_post()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return new; end if;
  if tg_op = 'INSERT' then
    new.pinned := false; new.created_at := now();
    if not public.lg_is_owner() and
       (select count(*) from public.lg_posts where user_id = new.user_id and created_at > now() - interval '10 minutes') >= 10 then
      raise exception 'وصلت إلى الحد المسموح (10 منشورات كل 10 دقائق). حاول لاحقاً';
    end if;
  else
    new.created_at := old.created_at;
    if new.pinned is distinct from old.pinned and not public.lg_is_owner() then
      raise exception 'التثبيت للمالك فقط';
    end if;
  end if;
  if new.image_url is not null and new.image_url not like public.lg_media_prefix() || new.user_id::text || '/%' then
    raise exception 'رابط الصورة غير مسموح';
  end if;
  return new;
end $$;

create or replace function public.lg_guard_comment()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return new; end if;
  new.created_at := now();
  if not public.lg_is_owner() and
     (select count(*) from public.lg_comments where user_id = new.user_id and created_at > now() - interval '10 minutes') >= 30 then
    raise exception 'وصلت إلى الحد المسموح من التعليقات. حاول بعد قليل';
  end if;
  return new;
end $$;

create or replace function public.lg_notify()
returns trigger language plpgsql security definer set search_path = public as $$
declare target uuid;
begin
  if tg_table_name = 'lg_likes' then
    select user_id into target from public.lg_posts where id = new.post_id;
    if target is not null and target <> new.user_id and not exists (
      select 1 from public.lg_notifications where user_id = target and actor_id = new.user_id
        and type = 'like' and post_id = new.post_id and created_at > now() - interval '1 day') then
      insert into public.lg_notifications (user_id, actor_id, type, post_id) values (target, new.user_id, 'like', new.post_id);
    end if;
  elsif tg_table_name = 'lg_comments' then
    select user_id into target from public.lg_posts where id = new.post_id;
    if target is not null and target <> new.user_id then
      insert into public.lg_notifications (user_id, actor_id, type, post_id) values (target, new.user_id, 'comment', new.post_id);
    end if;
  elsif tg_table_name = 'lg_follows' then
    if not exists (select 1 from public.lg_notifications where user_id = new.following_id and actor_id = new.follower_id
        and type = 'follow' and created_at > now() - interval '1 day') then
      insert into public.lg_notifications (user_id, actor_id, type) values (new.following_id, new.follower_id, 'follow');
    end if;
  end if;
  return new;
end $$;

revoke execute on function public.lg_guard_post(), public.lg_guard_comment(), public.lg_notify() from public, anon, authenticated;

commit;
