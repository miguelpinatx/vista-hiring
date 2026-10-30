-- Vista Hiring Tracker: store manager access
-- Run once in Supabase SQL Editor AFTER schema.sql. Safe to run again.
--
-- Store managers:
--   * are rows in public.staff with a store set (office staff have store = null)
--   * never read public.candidates directly; they get only name, phone, email,
--     position and availability through public.store_applicants()
--   * see only applicants the office has shared with their store
--   * can claim a shared applicant, add store notes, and request approval to hire

-- 1. Role: a store on the staff row makes someone a store manager.
alter table public.staff add column if not exists store text;

-- Office staff = on the team with no store. Only they get full access.
create or replace function public.is_staff() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.staff where email = lower(auth.jwt() ->> 'email') and store is null);
$$;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.staff where email = lower(auth.jwt() ->> 'email') and is_admin and store is null);
$$;

create or replace function public.my_store() returns text
language sql stable security definer set search_path = public as $$
  select store from public.staff where email = lower(auth.jwt() ->> 'email') and store is not null limit 1;
$$;

revoke all on function public.my_store() from public, anon;
grant execute on function public.my_store() to authenticated;

-- Team list: office staff see everyone; a store manager sees only their own row.
drop policy if exists "see own row or team" on public.staff;
create policy "see own row or team" on public.staff for select to authenticated
  using (email = lower(auth.jwt() ->> 'email') or public.is_staff());

-- 2. Which applicants are shared with which store.
create table if not exists public.shares (
  candidate_id text not null references public.candidates(id) on delete cascade,
  store        text not null,
  shared_at    timestamptz not null default now(),
  shared_by    text,
  claimed_at   timestamptz,
  claimed_by   text,
  primary key (candidate_id, store)
);

-- 3. Notes visible to the store (separate from the office's private notes).
create table if not exists public.store_notes (
  id           uuid primary key default gen_random_uuid(),
  candidate_id text not null references public.candidates(id) on delete cascade,
  store        text not null,
  author       text,
  author_email text not null default lower(auth.jwt() ->> 'email'),
  body         text not null check (length(body) between 1 and 4000),
  created_at   timestamptz not null default now()
);

-- 4. Requests from a store to hire someone.
create table if not exists public.hire_requests (
  id              uuid primary key default gen_random_uuid(),
  candidate_id    text not null references public.candidates(id) on delete cascade,
  store           text not null,
  requested_by    text,
  requested_email text not null default lower(auth.jwt() ->> 'email'),
  position        text,
  pay             text,
  start_date      date,
  note            text,
  status          text not null default 'pending' check (status in ('pending','approved','declined','cancelled')),
  decided_by      text,
  decided_at      timestamptz,
  decision_note   text,
  created_at      timestamptz not null default now()
);

alter table public.shares        enable row level security;
alter table public.store_notes   enable row level security;
alter table public.hire_requests enable row level security;
revoke all on public.shares, public.store_notes, public.hire_requests from anon;
grant select, insert, update, delete on public.shares, public.store_notes, public.hire_requests to authenticated;

-- shares: office manages them; a store manager can see their store's rows.
drop policy if exists "shares read"  on public.shares;
drop policy if exists "shares write" on public.shares;
create policy "shares read"  on public.shares for select to authenticated using (public.is_staff() or store = public.my_store());
create policy "shares write" on public.shares for all    to authenticated using (public.is_staff()) with check (public.is_staff());

-- store notes: office sees all; a store sees and writes its own, only on applicants shared with it.
drop policy if exists "store notes read"   on public.store_notes;
drop policy if exists "store notes add"    on public.store_notes;
drop policy if exists "store notes remove" on public.store_notes;
create policy "store notes read" on public.store_notes for select to authenticated
  using (public.is_staff() or store = public.my_store());
create policy "store notes add" on public.store_notes for insert to authenticated
  with check (
    author_email = lower(auth.jwt() ->> 'email') and (
      public.is_staff()
      or (store = public.my_store() and exists (select 1 from public.shares s where s.candidate_id = store_notes.candidate_id and s.store = store_notes.store))
    ));
create policy "store notes remove" on public.store_notes for delete to authenticated
  using (public.is_staff() or author_email = lower(auth.jwt() ->> 'email'));

-- hire requests: a store can ask only for applicants it has claimed; only the office decides.
drop policy if exists "requests read"   on public.hire_requests;
drop policy if exists "requests add"    on public.hire_requests;
drop policy if exists "requests update" on public.hire_requests;
create policy "requests read" on public.hire_requests for select to authenticated
  using (public.is_staff() or store = public.my_store());
create policy "requests add" on public.hire_requests for insert to authenticated
  with check (
    status = 'pending' and requested_email = lower(auth.jwt() ->> 'email')
    and store = public.my_store()
    and exists (select 1 from public.shares s where s.candidate_id = hire_requests.candidate_id and s.store = hire_requests.store and s.claimed_at is not null));
create policy "requests update" on public.hire_requests for update to authenticated
  using (public.is_staff() or (store = public.my_store() and status = 'pending'))
  with check (public.is_staff() or (store = public.my_store() and status = 'cancelled'));

-- 5. What a store manager can read about an applicant: only these fields.
create or replace function public.store_applicants()
returns table (
  id text, name text, phone text, email text,
  position_wanted text, hire_for text, employment_type text, shift text,
  can_start text, availability text, avail_days jsonb, form_language text,
  shared_at timestamptz, claimed_at timestamptz, claimed_by text
)
language sql stable security definer set search_path = public as $$
  select c.id,
         c.data->>'name', c.data->>'phone', c.data->>'email',
         c.data->>'position', c.data->>'hireFor', c.data->>'employmentType', c.data->>'shift',
         c.data->>'startDate', c.data->>'availability', coalesce(c.data->'availDays','[]'::jsonb), c.data->>'formLanguage',
         s.shared_at, s.claimed_at, s.claimed_by
  from public.shares s
  join public.candidates c on c.id = s.candidate_id
  where s.store = public.my_store()
  order by s.shared_at desc;
$$;
revoke all on function public.store_applicants() from public, anon;
grant execute on function public.store_applicants() to authenticated;

-- 6. Claim: the store takes the applicant. Other stores' shares are removed
--    and the applicant's store is set, so nobody else can claim them.
create or replace function public.claim_applicant(cid text, who text default null)
returns boolean
language plpgsql security definer set search_path = public as $$
declare st text := public.my_store();
begin
  if st is null then raise exception 'Only store managers can claim applicants'; end if;
  if not exists (select 1 from public.shares where candidate_id = cid and store = st) then
    raise exception 'This applicant is not shared with your store';
  end if;
  if exists (select 1 from public.shares where candidate_id = cid and store <> st and claimed_at is not null) then
    raise exception 'Another store already claimed this applicant';
  end if;
  update public.shares set claimed_at = coalesce(claimed_at, now()), claimed_by = coalesce(claimed_by, who, lower(auth.jwt() ->> 'email'))
   where candidate_id = cid and store = st;
  delete from public.shares where candidate_id = cid and store <> st;
  update public.candidates
     set data = jsonb_set(data, '{store}', to_jsonb(st)), updated_at = now()
   where id = cid;
  return true;
end $$;
revoke all on function public.claim_applicant(text, text) from public, anon;
grant execute on function public.claim_applicant(text, text) to authenticated;

-- 7. Live updates.
do $$
begin
  begin alter publication supabase_realtime add table public.shares;        exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.store_notes;   exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.hire_requests; exception when duplicate_object then null; end;
end $$;

-- 8. Scheduling: the office marks onboarding complete, the store confirms the start date and time.
alter table public.hire_requests
  add column if not exists ready_at             timestamptz,
  add column if not exists ready_by             text,
  add column if not exists ready_note           text,
  add column if not exists start_date_confirmed date,
  add column if not exists start_time           text,
  add column if not exists confirmed_by         text,
  add column if not exists confirmed_at         timestamptz,
  add column if not exists confirm_note         text;

-- The office can also send someone it hired directly (no store request) to a store for scheduling.
drop policy if exists "requests add office" on public.hire_requests;
create policy "requests add office" on public.hire_requests for insert to authenticated
  with check (public.is_staff());

drop function if exists public.confirm_start(uuid, date, text, text, text);
create function public.confirm_start(rid uuid, sdate date, stime text, snote text default null, who text default null)
returns boolean
language plpgsql security definer set search_path = public as $$
declare
  st text := public.my_store();
  r  public.hire_requests;
  w  text := coalesce(nullif(who, ''), lower(auth.jwt() ->> 'email'));
  ms bigint := floor(extract(epoch from clock_timestamp()) * 1000)::bigint;
begin
  if st is null then raise exception 'Only store managers can confirm start dates'; end if;
  select * into r from public.hire_requests where id = rid and store = st;
  if not found then raise exception 'Request not found for your store'; end if;
  if r.status <> 'approved' or r.ready_at is null then raise exception 'This applicant is not ready to schedule yet'; end if;
  if sdate is null or stime is null or stime !~ '^\d{2}:\d{2}$' then raise exception 'Start date and time are required'; end if;
  update public.hire_requests
     set start_date_confirmed = sdate, start_time = stime, confirmed_by = w, confirmed_at = now(), confirm_note = nullif(snote, '')
   where id = rid;
  update public.candidates
     set data = data || jsonb_build_object(
           'offerStart', to_char(sdate, 'YYYY-MM-DD'),
           'offerStartTime', stime,
           'notesLog', coalesce(data -> 'notesLog', '[]'::jsonb) || jsonb_build_array(jsonb_build_object(
              'id', 'n' || ms::text,
              'text', st || ' confirmed first day: ' || to_char(sdate, 'Dy Mon FMDD') || ' at ' ||
                      to_char(('2000-01-01 ' || stime)::timestamp, 'FMHH12:MI AM') ||
                      coalesce(' — ' || nullif(snote, ''), ''),
              'at', ms,
              'by', w))),
         updated_at = now()
   where id = r.candidate_id;
  return true;
end $$;
revoke all on function public.confirm_start(uuid, date, text, text, text) from public, anon;
grant execute on function public.confirm_start(uuid, date, text, text, text) to authenticated;
