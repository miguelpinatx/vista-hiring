-- Vista Hiring Tracker: database setup
-- Run this once in Supabase: SQL Editor -> New query -> paste -> Run.
-- Safe to run again; it won't duplicate anything.

-- 1. Team allow-list. Only emails in this table can see or change applicants.
create table if not exists public.staff (
  email     text primary key check (email = lower(email)),
  name      text,
  is_admin  boolean not null default false,
  added_at  timestamptz not null default now()
);

-- Seed the first admin. Change the email if you sign in with a different one.
insert into public.staff (email, name, is_admin)
values ('miguel@vistasupermarkets.com', 'Miguel Piña', true)
on conflict (email) do update set is_admin = true;

-- 2. Helper checks used by the access rules below.
create or replace function public.is_staff() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.staff where email = lower(auth.jwt() ->> 'email'));
$$;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.staff where email = lower(auth.jwt() ->> 'email') and is_admin);
$$;

revoke all on function public.is_staff() from public, anon;
revoke all on function public.is_admin() from public, anon;
grant execute on function public.is_staff() to authenticated;
grant execute on function public.is_admin() to authenticated;

-- 3. Data tables. Each row holds one record as JSON, mirroring the app.
create table if not exists public.candidates (
  id          text primary key,
  data        jsonb not null,
  updated_at  timestamptz not null default now()
);

create table if not exists public.openings (
  id          text primary key,
  data        jsonb not null,
  updated_at  timestamptz not null default now()
);

create table if not exists public.settings (
  key         text primary key,
  value       jsonb not null,
  updated_at  timestamptz not null default now()
);

-- 4. Access rules (row level security). Nobody signed out can read anything.
alter table public.staff      enable row level security;
alter table public.candidates enable row level security;
alter table public.openings   enable row level security;
alter table public.settings   enable row level security;

revoke all on public.staff, public.candidates, public.openings, public.settings from anon;
grant select, insert, update, delete on public.candidates, public.openings, public.settings to authenticated;
grant select, insert, delete on public.staff to authenticated;

drop policy if exists "team reads candidates"  on public.candidates;
drop policy if exists "team writes candidates" on public.candidates;
create policy "team reads candidates"  on public.candidates for select to authenticated using (public.is_staff());
create policy "team writes candidates" on public.candidates for all    to authenticated using (public.is_staff()) with check (public.is_staff());

drop policy if exists "team reads openings"  on public.openings;
drop policy if exists "team writes openings" on public.openings;
create policy "team reads openings"  on public.openings for select to authenticated using (public.is_staff());
create policy "team writes openings" on public.openings for all    to authenticated using (public.is_staff()) with check (public.is_staff());

drop policy if exists "team reads settings"  on public.settings;
drop policy if exists "team writes settings" on public.settings;
create policy "team reads settings"  on public.settings for select to authenticated using (public.is_staff());
create policy "team writes settings" on public.settings for all    to authenticated using (public.is_staff()) with check (public.is_staff());

-- Team list: you can always see your own row (so the app can tell you're on the team);
-- team members see the whole list; only admins add or remove people.
drop policy if exists "see own row or team"  on public.staff;
drop policy if exists "admins add people"    on public.staff;
drop policy if exists "admins remove people" on public.staff;
create policy "see own row or team"  on public.staff for select to authenticated
  using (email = lower(auth.jwt() ->> 'email') or public.is_staff());
create policy "admins add people"    on public.staff for insert to authenticated
  with check (public.is_admin() and is_admin = false);
create policy "admins remove people" on public.staff for delete to authenticated
  using (public.is_admin() and email <> lower(auth.jwt() ->> 'email'));

-- 5. Live updates, so changes show up on every open device right away.
do $$
begin
  begin alter publication supabase_realtime add table public.candidates; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.openings;   exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.settings;   exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.staff;      exception when duplicate_object then null; end;
end $$;
