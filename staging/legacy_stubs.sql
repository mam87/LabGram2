-- Stand-ins for the pre-LabGram2 prototype objects that exist in the production project.
-- Shapes reproduce what matters for tests: the legacy signup trigger, its username rules
-- (lowercased + unique), and the two legacy buckets.
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text unique,
  display_name text check (length(display_name) between 1 and 80),
  bio text, specialty text,
  role text default 'user'
);
create or replace function public.validate_username() returns trigger language plpgsql as $$
begin
  new.username = lower(trim(new.username));
  if new.username !~ '^[a-zA-Z0-9_.]{3,30}$' then
    raise exception 'Username must contain only letters, numbers, underscore or dot and be 3-30 characters';
  end if;
  return new;
end $$;
create or replace function public.update_updated_at() returns trigger language plpgsql as $$ begin return new; end $$;
drop trigger if exists validate_username_trigger on public.profiles;
create trigger validate_username_trigger before insert or update on public.profiles
  for each row execute function public.validate_username();

create table if not exists public.posts (id uuid primary key default gen_random_uuid(), user_id uuid);
create table if not exists public.likes (id uuid primary key default gen_random_uuid());
create table if not exists public.comments (id uuid primary key default gen_random_uuid());
create table if not exists public.follows (id uuid primary key default gen_random_uuid());
create table if not exists public.conversations (id uuid primary key default gen_random_uuid());
create table if not exists public.conversation_members (id uuid primary key default gen_random_uuid());
create table if not exists public.messages (id uuid primary key default gen_random_uuid());
create table if not exists public.notifications (id uuid primary key default gen_random_uuid(), user_id uuid);
create table if not exists public.reports (id uuid primary key default gen_random_uuid());
grant all on public.profiles, public.posts, public.notifications to anon, authenticated;

create or replace function public.handle_new_user() returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  insert into public.profiles (id, username, display_name, bio, specialty)
  values (new.id, coalesce(new.raw_user_meta_data->>'username', split_part(new.email,'@',1)),
          coalesce(new.raw_user_meta_data->>'display_name', split_part(new.email,'@',1)), '', 'General');
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users for each row execute function public.handle_new_user();

insert into storage.buckets (id, name, public) values ('avatars','avatars',true), ('post-images','post-images',true)
on conflict (id) do nothing;
