-- =====================================================================
--  LabGram — إعداد قاعدة البيانات (Supabase)
--  شغّل هذا الملف مرة واحدة كاملاً من: Supabase → SQL Editor → New query
--  آمن لإعادة التشغيل (لا يحذف أي بيانات).
--  كل الجداول تبدأ بـ lg_ حتى لا تتعارض مع أي جداول قديمة في المشروع.
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- 1) الجداول
-- ---------------------------------------------------------------------
create table if not exists public.lg_profiles (
  id           uuid primary key references auth.users(id) on delete cascade,
  username     text not null unique check (username ~ '^[A-Za-z0-9_.]{3,30}$'),
  display_name text,
  specialty    text default 'General',
  bio          text default '' check (char_length(bio) <= 300),
  avatar_url   text,
  cover        text default 'aurora',
  role         text not null default 'user' check (role in ('user','owner')),
  created_at   timestamptz not null default now()
);

create table if not exists public.lg_posts (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null,
  body       text not null default '' check (char_length(body) <= 2000),
  image_url  text,
  category   text not null default 'General',
  created_at timestamptz not null default now(),
  constraint lg_posts_user_id_fkey foreign key (user_id) references public.lg_profiles(id) on delete cascade,
  constraint lg_posts_not_empty check (char_length(body) > 0 or image_url is not null)
);

create table if not exists public.lg_likes (
  post_id    uuid not null references public.lg_posts(id) on delete cascade,
  user_id    uuid not null references public.lg_profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (post_id, user_id)
);

create table if not exists public.lg_comments (
  id         uuid primary key default gen_random_uuid(),
  post_id    uuid not null references public.lg_posts(id) on delete cascade,
  user_id    uuid not null,
  body       text not null check (char_length(body) between 1 and 1000),
  created_at timestamptz not null default now(),
  constraint lg_comments_user_id_fkey foreign key (user_id) references public.lg_profiles(id) on delete cascade
);

create table if not exists public.lg_follows (
  follower_id  uuid not null references public.lg_profiles(id) on delete cascade,
  following_id uuid not null references public.lg_profiles(id) on delete cascade,
  created_at   timestamptz not null default now(),
  primary key (follower_id, following_id),
  check (follower_id <> following_id)
);

create table if not exists public.lg_notifications (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null,
  actor_id   uuid not null,
  type       text not null check (type in ('like','comment','follow')),
  post_id    uuid references public.lg_posts(id) on delete cascade,
  read       boolean not null default false,
  created_at timestamptz not null default now(),
  constraint lg_notifications_user_id_fkey  foreign key (user_id)  references public.lg_profiles(id) on delete cascade,
  constraint lg_notifications_actor_id_fkey foreign key (actor_id) references public.lg_profiles(id) on delete cascade
);

create index if not exists lg_posts_created_idx    on public.lg_posts (created_at desc);
create index if not exists lg_posts_user_idx       on public.lg_posts (user_id);
create index if not exists lg_comments_post_idx    on public.lg_comments (post_id, created_at);
create index if not exists lg_follows_following_idx on public.lg_follows (following_id);
create index if not exists lg_notif_user_idx       on public.lg_notifications (user_id, created_at desc);

-- ---------------------------------------------------------------------
-- 2) صلاحية المالك (owner)
-- ---------------------------------------------------------------------
create or replace function public.lg_is_owner()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.lg_profiles where id = auth.uid() and role = 'owner');
$$;

-- لا يستطيع أي مستخدم ترقية نفسه؛ فقط المالك أو محرر SQL
create or replace function public.lg_guard_role()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return new; end if;            -- SQL Editor / النظام
  if tg_op = 'INSERT' then new.role := 'user'; return new; end if;
  if new.role is distinct from old.role and not public.lg_is_owner() then
    raise exception 'غير مسموح بتغيير الصلاحية';
  end if;
  return new;
end $$;

drop trigger if exists lg_guard_role on public.lg_profiles;
create trigger lg_guard_role before insert or update on public.lg_profiles
  for each row execute function public.lg_guard_role();

-- ---------------------------------------------------------------------
-- 3) إنشاء الملف الشخصي تلقائياً عند التسجيل
-- ---------------------------------------------------------------------
create or replace function public.lg_handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.lg_profiles (id, username, display_name, specialty, bio)
  values (
    new.id,
    coalesce(nullif(new.raw_user_meta_data->>'username',''), 'user_' || left(new.id::text, 8)),
    coalesce(new.raw_user_meta_data->>'display_name', ''),
    coalesce(nullif(new.raw_user_meta_data->>'specialty',''), 'General'),
    coalesce(new.raw_user_meta_data->>'bio', '')
  )
  on conflict do nothing;
  return new;
exception when others then
  return new;   -- لا نمنع التسجيل أبداً؛ التطبيق يكمل الملف لاحقاً
end $$;

drop trigger if exists lg_on_auth_user_created on auth.users;
create trigger lg_on_auth_user_created after insert on auth.users
  for each row execute function public.lg_handle_new_user();

-- ملفات للحسابات الموجودة مسبقاً
insert into public.lg_profiles (id, username, display_name, specialty, bio)
select u.id,
       coalesce(nullif(u.raw_user_meta_data->>'username',''), 'user_' || left(u.id::text, 8)),
       coalesce(u.raw_user_meta_data->>'display_name', ''),
       coalesce(nullif(u.raw_user_meta_data->>'specialty',''), 'General'),
       coalesce(u.raw_user_meta_data->>'bio', '')
from auth.users u
on conflict do nothing;

-- ---------------------------------------------------------------------
-- 4) التنبيهات التلقائية
-- ---------------------------------------------------------------------
create or replace function public.lg_notify()
returns trigger language plpgsql security definer set search_path = public as $$
declare target uuid;
begin
  if tg_table_name = 'lg_likes' then
    select user_id into target from public.lg_posts where id = new.post_id;
    if target is not null and target <> new.user_id then
      insert into public.lg_notifications (user_id, actor_id, type, post_id) values (target, new.user_id, 'like', new.post_id);
    end if;
  elsif tg_table_name = 'lg_comments' then
    select user_id into target from public.lg_posts where id = new.post_id;
    if target is not null and target <> new.user_id then
      insert into public.lg_notifications (user_id, actor_id, type, post_id) values (target, new.user_id, 'comment', new.post_id);
    end if;
  elsif tg_table_name = 'lg_follows' then
    insert into public.lg_notifications (user_id, actor_id, type) values (new.following_id, new.follower_id, 'follow');
  end if;
  return new;
end $$;

drop trigger if exists lg_notify_like    on public.lg_likes;
drop trigger if exists lg_notify_comment on public.lg_comments;
drop trigger if exists lg_notify_follow  on public.lg_follows;
create trigger lg_notify_like    after insert on public.lg_likes    for each row execute function public.lg_notify();
create trigger lg_notify_comment after insert on public.lg_comments for each row execute function public.lg_notify();
create trigger lg_notify_follow  after insert on public.lg_follows  for each row execute function public.lg_notify();

-- ---------------------------------------------------------------------
-- 5) الصلاحيات و RLS
-- ---------------------------------------------------------------------
grant usage on schema public to anon, authenticated;
grant select on public.lg_profiles, public.lg_posts, public.lg_likes, public.lg_comments, public.lg_follows to anon, authenticated;
grant insert, update, delete on public.lg_profiles, public.lg_posts, public.lg_likes, public.lg_comments, public.lg_follows to authenticated;
grant select, update, delete on public.lg_notifications to authenticated;
revoke execute on function public.lg_guard_role(), public.lg_handle_new_user(), public.lg_notify() from public, anon, authenticated;
revoke execute on function public.lg_is_owner() from public, anon;
grant execute on function public.lg_is_owner() to authenticated;

alter table public.lg_profiles      enable row level security;
alter table public.lg_posts         enable row level security;
alter table public.lg_likes         enable row level security;
alter table public.lg_comments      enable row level security;
alter table public.lg_follows       enable row level security;
alter table public.lg_notifications enable row level security;

-- profiles
drop policy if exists lg_profiles_read   on public.lg_profiles;
drop policy if exists lg_profiles_insert on public.lg_profiles;
drop policy if exists lg_profiles_update on public.lg_profiles;
create policy lg_profiles_read   on public.lg_profiles for select using (true);
create policy lg_profiles_insert on public.lg_profiles for insert to authenticated with check (id = auth.uid());
create policy lg_profiles_update on public.lg_profiles for update to authenticated
  using (id = auth.uid() or public.lg_is_owner()) with check (id = auth.uid() or public.lg_is_owner());

-- posts
drop policy if exists lg_posts_read   on public.lg_posts;
drop policy if exists lg_posts_insert on public.lg_posts;
drop policy if exists lg_posts_update on public.lg_posts;
drop policy if exists lg_posts_delete on public.lg_posts;
create policy lg_posts_read   on public.lg_posts for select using (true);
create policy lg_posts_insert on public.lg_posts for insert to authenticated with check (user_id = auth.uid());
create policy lg_posts_update on public.lg_posts for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy lg_posts_delete on public.lg_posts for delete to authenticated using (user_id = auth.uid() or public.lg_is_owner());

-- likes
drop policy if exists lg_likes_read   on public.lg_likes;
drop policy if exists lg_likes_insert on public.lg_likes;
drop policy if exists lg_likes_delete on public.lg_likes;
create policy lg_likes_read   on public.lg_likes for select using (true);
create policy lg_likes_insert on public.lg_likes for insert to authenticated with check (user_id = auth.uid());
create policy lg_likes_delete on public.lg_likes for delete to authenticated using (user_id = auth.uid());

-- comments
drop policy if exists lg_comments_read   on public.lg_comments;
drop policy if exists lg_comments_insert on public.lg_comments;
drop policy if exists lg_comments_delete on public.lg_comments;
create policy lg_comments_read   on public.lg_comments for select using (true);
create policy lg_comments_insert on public.lg_comments for insert to authenticated with check (user_id = auth.uid());
create policy lg_comments_delete on public.lg_comments for delete to authenticated using (
  user_id = auth.uid() or public.lg_is_owner()
  or exists (select 1 from public.lg_posts p where p.id = post_id and p.user_id = auth.uid())
);

-- follows
drop policy if exists lg_follows_read   on public.lg_follows;
drop policy if exists lg_follows_insert on public.lg_follows;
drop policy if exists lg_follows_delete on public.lg_follows;
create policy lg_follows_read   on public.lg_follows for select using (true);
create policy lg_follows_insert on public.lg_follows for insert to authenticated with check (follower_id = auth.uid());
create policy lg_follows_delete on public.lg_follows for delete to authenticated using (follower_id = auth.uid());

-- notifications (كل شخص يرى تنبيهاته فقط)
drop policy if exists lg_notif_read   on public.lg_notifications;
drop policy if exists lg_notif_update on public.lg_notifications;
drop policy if exists lg_notif_delete on public.lg_notifications;
create policy lg_notif_read   on public.lg_notifications for select to authenticated using (user_id = auth.uid());
create policy lg_notif_update on public.lg_notifications for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy lg_notif_delete on public.lg_notifications for delete to authenticated using (user_id = auth.uid());

-- ---------------------------------------------------------------------
-- 6) تخزين الصور (bucket عام للقراءة، كل مستخدم يرفع في مجلده فقط)
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('lg-media', 'lg-media', true, 5242880, array['image/jpeg','image/png','image/webp','image/gif'])
on conflict (id) do update set public = true;

drop policy if exists lg_media_insert on storage.objects;
drop policy if exists lg_media_update on storage.objects;
drop policy if exists lg_media_delete on storage.objects;
create policy lg_media_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'lg-media' and (storage.foldername(name))[1] = auth.uid()::text);
create policy lg_media_update on storage.objects for update to authenticated
  using (bucket_id = 'lg-media' and (storage.foldername(name))[1] = auth.uid()::text);
create policy lg_media_delete on storage.objects for delete to authenticated
  using (bucket_id = 'lg-media' and (storage.foldername(name))[1] = auth.uid()::text);

-- ---------------------------------------------------------------------
-- 7) اجعل حسابك مالكاً (بعد أن تسجّل في الموقع) — غيّر mam87 لاسم مستخدمك
-- ---------------------------------------------------------------------
-- update public.lg_profiles set role = 'owner' where username = 'mam87';

-- =====================================================================
-- 8) لوحة تحكم المالك: التوثيق، الإيقاف، التثبيت، البلاغات
-- =====================================================================
alter table public.lg_profiles add column if not exists verified boolean not null default false;
alter table public.lg_profiles add column if not exists banned boolean not null default false;
alter table public.lg_posts add column if not exists pinned boolean not null default false;

create table if not exists public.lg_reports (
  id          uuid primary key default gen_random_uuid(),
  post_id     uuid not null references public.lg_posts(id) on delete cascade,
  reporter_id uuid not null,
  reason      text not null check (char_length(reason) between 1 and 300),
  status      text not null default 'open' check (status in ('open','resolved')),
  created_at  timestamptz not null default now(),
  constraint lg_reports_reporter_id_fkey foreign key (reporter_id) references public.lg_profiles(id) on delete cascade,
  constraint lg_reports_once unique (post_id, reporter_id)
);
create index if not exists lg_reports_status_idx on public.lg_reports (status, created_at desc);
create index if not exists lg_posts_pinned_idx on public.lg_posts (pinned) where pinned;

create or replace function public.lg_is_banned()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.lg_profiles where id = auth.uid() and banned);
$$;
revoke execute on function public.lg_is_banned() from public, anon;
grant execute on function public.lg_is_banned() to authenticated;

create or replace function public.lg_guard_role()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return new; end if;
  if tg_op = 'INSERT' then
    new.role := 'user'; new.verified := false; new.banned := false; return new;
  end if;
  if (new.role is distinct from old.role or new.verified is distinct from old.verified or new.banned is distinct from old.banned)
     and not public.lg_is_owner() then
    raise exception 'غير مسموح بتغيير الصلاحيات';
  end if;
  return new;
end $$;

create or replace function public.lg_guard_post()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return new; end if;
  if tg_op = 'INSERT' then new.pinned := false; return new; end if;
  if new.pinned is distinct from old.pinned and not public.lg_is_owner() then
    raise exception 'التثبيت للمالك فقط';
  end if;
  return new;
end $$;
drop trigger if exists lg_guard_post on public.lg_posts;
create trigger lg_guard_post before insert or update on public.lg_posts
  for each row execute function public.lg_guard_post();
revoke execute on function public.lg_guard_post() from public, anon, authenticated;

drop policy if exists lg_posts_owner_update   on public.lg_posts;
drop policy if exists lg_posts_not_banned     on public.lg_posts;
drop policy if exists lg_comments_not_banned  on public.lg_comments;
drop policy if exists lg_likes_not_banned     on public.lg_likes;
drop policy if exists lg_follows_not_banned   on public.lg_follows;
create policy lg_posts_owner_update on public.lg_posts for update to authenticated
  using (public.lg_is_owner()) with check (public.lg_is_owner());
create policy lg_posts_not_banned    on public.lg_posts    as restrictive for insert to authenticated with check (not public.lg_is_banned());
create policy lg_comments_not_banned on public.lg_comments as restrictive for insert to authenticated with check (not public.lg_is_banned());
create policy lg_likes_not_banned    on public.lg_likes    as restrictive for insert to authenticated with check (not public.lg_is_banned());
create policy lg_follows_not_banned  on public.lg_follows  as restrictive for insert to authenticated with check (not public.lg_is_banned());

grant select, insert, update, delete on public.lg_reports to authenticated;
alter table public.lg_reports enable row level security;
drop policy if exists lg_reports_insert       on public.lg_reports;
drop policy if exists lg_reports_not_banned   on public.lg_reports;
drop policy if exists lg_reports_owner_read   on public.lg_reports;
drop policy if exists lg_reports_owner_update on public.lg_reports;
drop policy if exists lg_reports_owner_delete on public.lg_reports;
create policy lg_reports_insert       on public.lg_reports for insert to authenticated with check (reporter_id = auth.uid());
create policy lg_reports_not_banned   on public.lg_reports as restrictive for insert to authenticated with check (not public.lg_is_banned());
create policy lg_reports_owner_read   on public.lg_reports for select to authenticated using (public.lg_is_owner());
create policy lg_reports_owner_update on public.lg_reports for update to authenticated using (public.lg_is_owner()) with check (public.lg_is_owner());
create policy lg_reports_owner_delete on public.lg_reports for delete to authenticated using (public.lg_is_owner());

create or replace function public.lg_admin_users()
returns table (id uuid, email text, last_sign_in_at timestamptz, confirmed boolean)
language plpgsql stable security definer set search_path = public, auth as $$
begin
  if not public.lg_is_owner() then raise exception 'غير مسموح'; end if;
  return query select u.id, u.email::text, u.last_sign_in_at, (u.email_confirmed_at is not null) from auth.users u;
end $$;
revoke execute on function public.lg_admin_users() from public, anon;
grant execute on function public.lg_admin_users() to authenticated;

-- =====================================================================
-- 9) تدقيق ما قبل الإطلاق (2026-10-10): حماية إضافية
--    مطبّق على المشروع الحالي كـ migration: labgram_audit_hardening
-- =====================================================================
-- (أ) تريغر التسجيل القديم لا يمنع التسجيل أبداً (كان يفشل مع أسماء تختلف بحالة الأحرف)
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  begin
    insert into public.profiles (id, username, display_name, bio, specialty)
    values (new.id,
      coalesce(new.raw_user_meta_data->>'username', split_part(new.email,'@',1)),
      coalesce(new.raw_user_meta_data->>'display_name', split_part(new.email,'@',1)),
      coalesce(new.raw_user_meta_data->>'bio', ''),
      coalesce(new.raw_user_meta_data->>'specialty', 'General'));
  exception when others then null;
  end;
  return new;
end $$;
-- ملاحظة: الدالة أعلاه تخص الجداول القديمة؛ في مشروع جديد بلا جدول profiles لا حاجة لها.

create or replace function public.lg_media_prefix()
returns text language sql immutable set search_path = '' as $$
  -- غيّر الرابط إذا نُقل المشروع إلى Supabase آخر
  select 'https://ualumobbhukgmjbznhea.supabase.co/storage/v1/object/public/lg-media/'::text;
$$;

create unique index if not exists lg_profiles_username_lower_idx on public.lg_profiles (lower(username));

create or replace function public.lg_username_available(u text)
returns boolean language sql stable security definer set search_path = public as $$
  select not exists (select 1 from public.lg_profiles where lower(username) = lower(trim(u)));
$$;
grant execute on function public.lg_username_available(text) to anon, authenticated;

create or replace function public.lg_guard_role()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' or new.username is distinct from old.username then
    new.username := lower(new.username);
  end if;
  if auth.uid() is null then return new; end if;
  if tg_op = 'INSERT' then
    new.role := 'user'; new.verified := false; new.banned := false; new.created_at := now();
  else
    new.created_at := old.created_at;
    if (new.role is distinct from old.role or new.verified is distinct from old.verified or new.banned is distinct from old.banned)
       and not public.lg_is_owner() then
      raise exception 'غير مسموح بتغيير الصلاحيات';
    end if;
  end if;
  if new.avatar_url is not null and new.avatar_url not like public.lg_media_prefix() || new.id::text || '/%' then
    raise exception 'رابط الصورة غير مسموح';
  end if;
  return new;
end $$;

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
drop trigger if exists lg_guard_comment on public.lg_comments;
create trigger lg_guard_comment before insert on public.lg_comments for each row execute function public.lg_guard_comment();

create or replace function public.lg_guard_report()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return new; end if;
  new.status := 'open'; new.created_at := now();
  if (select count(*) from public.lg_reports where reporter_id = new.reporter_id and created_at > now() - interval '1 hour') >= 20 then
    raise exception 'وصلت إلى الحد المسموح من البلاغات. حاول لاحقاً';
  end if;
  return new;
end $$;
drop trigger if exists lg_guard_report on public.lg_reports;
create trigger lg_guard_report before insert on public.lg_reports for each row execute function public.lg_guard_report();

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

do $$ begin
  if not exists (select 1 from pg_constraint where conname='lg_profiles_display_name_len') then
    alter table public.lg_profiles add constraint lg_profiles_display_name_len check (char_length(coalesce(display_name,'')) <= 60); end if;
  if not exists (select 1 from pg_constraint where conname='lg_profiles_specialty_len') then
    alter table public.lg_profiles add constraint lg_profiles_specialty_len check (char_length(coalesce(specialty,'')) <= 40); end if;
  if not exists (select 1 from pg_constraint where conname='lg_profiles_cover_valid') then
    alter table public.lg_profiles add constraint lg_profiles_cover_valid check (cover in ('aurora','sunset','ocean','night','rose','forest')); end if;
  if not exists (select 1 from pg_constraint where conname='lg_posts_category_valid') then
    alter table public.lg_posts add constraint lg_posts_category_valid check (category in ('General','Histopathology','Cytology','Microbiology','Hematology','Clinical Chemistry','Immunology','Molecular','Blood Bank','Laboratory Quality')); end if;
end $$;

revoke execute on function public.lg_guard_comment(), public.lg_guard_report(), public.handle_new_user() from public, anon, authenticated;
create index if not exists lg_comments_user_created_idx on public.lg_comments (user_id, created_at desc);
create index if not exists lg_notif_dedupe_idx on public.lg_notifications (user_id, actor_id, type, created_at desc);

-- =====================================================================
-- 10) خاص بهذا المشروع: إغلاق الجداول والمخازن القديمة (migration: labgram_legacy_lockdown)
--     البيانات محفوظة. للتراجع: grant select, insert, update, delete on <table> to authenticated;
-- =====================================================================
do $$ begin
  if to_regclass('public.profiles') is not null then
    revoke all on public.profiles, public.posts, public.likes, public.comments, public.follows,
                  public.conversations, public.conversation_members, public.messages,
                  public.notifications, public.reports from anon, authenticated;
  end if;
end $$;
drop policy if exists legacy_buckets_no_insert on storage.objects;
drop policy if exists legacy_buckets_no_update on storage.objects;
drop policy if exists legacy_buckets_no_list   on storage.objects;
create policy legacy_buckets_no_insert on storage.objects as restrictive for insert to public with check (bucket_id not in ('avatars','post-images'));
create policy legacy_buckets_no_update on storage.objects as restrictive for update to public using (bucket_id not in ('avatars','post-images'));
create policy legacy_buckets_no_list   on storage.objects as restrictive for select to public using (bucket_id not in ('avatars','post-images'));
