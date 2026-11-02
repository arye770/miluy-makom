-- מילוי מקום: הגדרת השרת. מריצים פעם אחת ב-Supabase: SQL Editor -> New query -> הדבקה -> Run
-- בטוח להריץ שוב: לא מוחק נתונים קיימים.

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text,
  full_name text,
  role text not null default 'pending' check (role in ('pending','viewer','editor','admin','blocked')),
  created_at timestamptz not null default now()
);

create table if not exists public.app_docs (
  path text primary key,
  data jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  client text
);

-- the signed-in user's role (security definer so policies can read it without recursion)
create or replace function public.my_role() returns text
language sql stable security definer set search_path = public as $$
  select role from public.profiles where id = auth.uid()
$$;

-- every new sign-up gets a profile; the very first one becomes the main admin
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, email, full_name, role)
  values (new.id, new.email, coalesce(new.raw_user_meta_data->>'full_name', ''),
          case when exists (select 1 from public.profiles where role = 'admin') then 'pending' else 'admin' end)
  on conflict (id) do nothing;
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- nobody changes their own role, and only the role can be changed
create or replace function public.guard_profile_update() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and new.id = auth.uid() and new.role <> old.role then
    raise exception 'cannot change your own role';
  end if;
  new.id := old.id; new.email := old.email; new.created_at := old.created_at;
  return new;
end $$;
drop trigger if exists profiles_guard on public.profiles;
create trigger profiles_guard before update on public.profiles
  for each row execute function public.guard_profile_update();

alter table public.profiles enable row level security;
alter table public.app_docs enable row level security;

drop policy if exists "profiles: read own or admin" on public.profiles;
create policy "profiles: read own or admin" on public.profiles for select to authenticated
  using (id = auth.uid() or public.my_role() = 'admin');
drop policy if exists "profiles: admin updates" on public.profiles;
create policy "profiles: admin updates" on public.profiles for update to authenticated
  using (public.my_role() = 'admin') with check (public.my_role() = 'admin');

drop policy if exists "docs: members read" on public.app_docs;
create policy "docs: members read" on public.app_docs for select to authenticated
  using (public.my_role() in ('viewer','editor','admin'));
drop policy if exists "docs: editors insert" on public.app_docs;
create policy "docs: editors insert" on public.app_docs for insert to authenticated
  with check (public.my_role() in ('editor','admin'));
drop policy if exists "docs: editors update" on public.app_docs;
create policy "docs: editors update" on public.app_docs for update to authenticated
  using (public.my_role() in ('editor','admin')) with check (public.my_role() in ('editor','admin'));
drop policy if exists "docs: editors delete" on public.app_docs;
create policy "docs: editors delete" on public.app_docs for delete to authenticated
  using (public.my_role() in ('editor','admin'));

revoke all on public.profiles, public.app_docs from anon;
grant select, update on public.profiles to authenticated;
grant select, insert, update, delete on public.app_docs to authenticated;

-- live sync between open screens
do $$ begin
  alter publication supabase_realtime add table public.app_docs;
exception when duplicate_object then null; end $$;
