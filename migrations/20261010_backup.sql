-- =====================================================================
-- Pre-migration snapshot (run BEFORE 20261010_beta_features.up.sql)
-- The project is on the Supabase Free plan, which has no managed/downloadable backups,
-- so we copy every LabGram table into a private schema inside the same database.
--   * The schema is not exposed through the API (no grants to anon/authenticated).
--   * It protects against a bad migration or bad data change; it does NOT protect against
--     loss of the whole project — for that, also take an off-site dump (see README).
-- Uploaded images live in Storage and are untouched by the migration.
-- =====================================================================
create schema if not exists lg_backup_20261010;
revoke all on schema lg_backup_20261010 from public, anon, authenticated;

create table lg_backup_20261010.lg_profiles      as table public.lg_profiles;
create table lg_backup_20261010.lg_posts         as table public.lg_posts;
create table lg_backup_20261010.lg_comments      as table public.lg_comments;
create table lg_backup_20261010.lg_likes         as table public.lg_likes;
create table lg_backup_20261010.lg_follows       as table public.lg_follows;
create table lg_backup_20261010.lg_notifications as table public.lg_notifications;
create table lg_backup_20261010.lg_reports       as table public.lg_reports;
create table lg_backup_20261010.storage_objects  as
  select id, bucket_id, name, owner, created_at from storage.objects where bucket_id = 'lg-media';

-- verification: counts must equal the live tables
select 'lg_profiles' t, (select count(*) from public.lg_profiles) live, (select count(*) from lg_backup_20261010.lg_profiles) backup
union all select 'lg_posts', (select count(*) from public.lg_posts), (select count(*) from lg_backup_20261010.lg_posts)
union all select 'lg_comments', (select count(*) from public.lg_comments), (select count(*) from lg_backup_20261010.lg_comments)
union all select 'lg_likes', (select count(*) from public.lg_likes), (select count(*) from lg_backup_20261010.lg_likes)
union all select 'lg_follows', (select count(*) from public.lg_follows), (select count(*) from lg_backup_20261010.lg_follows)
union all select 'lg_notifications', (select count(*) from public.lg_notifications), (select count(*) from lg_backup_20261010.lg_notifications)
union all select 'lg_reports', (select count(*) from public.lg_reports), (select count(*) from lg_backup_20261010.lg_reports)
union all select 'lg_media_objects', (select count(*) from storage.objects where bucket_id='lg-media'), (select count(*) from lg_backup_20261010.storage_objects);

-- RESTORE (only if needed, after rollback), table by table, e.g. comments lost by mistake:
--   insert into public.lg_comments (id, post_id, user_id, body, created_at)
--   select id, post_id, user_id, body, created_at from lg_backup_20261010.lg_comments
--   on conflict (id) do nothing;
-- Restoring re-inserts missing rows only; it never overwrites rows that exist.
