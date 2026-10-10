-- =====================================================================
-- LabGram beta features — forward migration (ADDITIVE ONLY)
--   1. Post editing      : lg_posts.edited_at + author-only content edits
--   2. Comment replies   : lg_comments.parent_id (one level) + reply notifications
--   3. Saved posts       : lg_saves (private per user)
-- No existing column, row, policy or table is dropped or rewritten.
-- Backward compatible: the currently deployed frontend keeps working unchanged.
-- =====================================================================

-- ---------- 1. POST EDITING ----------
alter table public.lg_posts add column if not exists edited_at timestamptz;

create or replace function public.lg_guard_post()
returns trigger language plpgsql security definer set search_path = public as $$
declare content_changed boolean;
begin
  if auth.uid() is null then return new; end if;
  if tg_op = 'INSERT' then
    new.pinned := false; new.created_at := now(); new.edited_at := null;
    if not public.lg_is_owner() and
       (select count(*) from public.lg_posts where user_id = new.user_id and created_at > now() - interval '10 minutes') >= 10 then
      raise exception 'وصلت إلى الحد المسموح (10 منشورات كل 10 دقائق). حاول لاحقاً';
    end if;
  else
    new.created_at := old.created_at;
    if new.user_id is distinct from old.user_id then
      raise exception 'لا يمكن نقل ملكية المنشور';
    end if;
    content_changed := new.body is distinct from old.body
                    or new.image_url is distinct from old.image_url
                    or new.category is distinct from old.category;
    if content_changed then
      -- only the author may change content; admins may pin/delete but never rewrite
      if auth.uid() <> old.user_id then
        raise exception 'لا يمكنك تعديل منشور شخص آخر';
      end if;
      new.edited_at := now();
    else
      new.edited_at := old.edited_at;  -- clients cannot fake the "edited" marker
    end if;
    if new.pinned is distinct from old.pinned and not public.lg_is_owner() then
      raise exception 'التثبيت للمالك فقط';
    end if;
  end if;
  if new.image_url is not null and new.image_url not like public.lg_media_prefix() || new.user_id::text || '/%' then
    raise exception 'رابط الصورة غير مسموح';
  end if;
  return new;
end $$;

-- suspended users cannot edit either (posting was already blocked)
create policy lg_posts_not_banned_update on public.lg_posts as restrictive for update to authenticated
  using (not public.lg_is_banned()) with check (not public.lg_is_banned());

-- ---------- 2. ONE-LEVEL COMMENT REPLIES ----------
alter table public.lg_comments add column if not exists parent_id uuid
  references public.lg_comments(id) on delete cascade;
create index if not exists lg_comments_parent_idx on public.lg_comments (parent_id) where parent_id is not null;

alter table public.lg_notifications add column if not exists comment_id uuid
  references public.lg_comments(id) on delete cascade;

create or replace function public.lg_guard_comment()
returns trigger language plpgsql security definer set search_path = public as $$
declare p record;
begin
  if new.parent_id is not null then
    select id, post_id, parent_id into p from public.lg_comments where id = new.parent_id;
    if p.id is null then raise exception 'التعليق الأصلي غير موجود'; end if;
    if p.post_id <> new.post_id then raise exception 'الرد يجب أن يكون على نفس المنشور'; end if;
    if p.parent_id is not null then
      new.parent_id := p.parent_id;  -- reply-to-reply attaches to the top-level comment (one level only)
    end if;
  end if;
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
declare target uuid; parent_author uuid;
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
    if new.parent_id is not null then
      select user_id into parent_author from public.lg_comments where id = new.parent_id;
      if parent_author is not null and parent_author <> new.user_id then
        insert into public.lg_notifications (user_id, actor_id, type, post_id, comment_id)
        values (parent_author, new.user_id, 'comment', new.post_id, new.id);
      end if;
    end if;
    -- post author is told about the comment unless they wrote it or already got the reply notice
    if target is not null and target <> new.user_id and target is distinct from parent_author then
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

-- ---------- 3. PRIVATE SAVED POSTS ----------
create table if not exists public.lg_saves (
  user_id    uuid not null references public.lg_profiles(id) on delete cascade,
  post_id    uuid not null references public.lg_posts(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, post_id)
);
create index if not exists lg_saves_user_idx on public.lg_saves (user_id, created_at desc);

alter table public.lg_saves enable row level security;
revoke all on public.lg_saves from anon, authenticated;        -- override Supabase default grants
grant select, insert, delete on public.lg_saves to authenticated;
create policy lg_saves_read   on public.lg_saves for select to authenticated using (user_id = auth.uid());
create policy lg_saves_insert on public.lg_saves for insert to authenticated with check (user_id = auth.uid());
create policy lg_saves_delete on public.lg_saves for delete to authenticated using (user_id = auth.uid());

-- trigger functions are never callable through the API
revoke execute on function public.lg_guard_post(), public.lg_guard_comment(), public.lg_notify() from public, anon, authenticated;
