-- Vista Hiring Tracker: stores request openings
-- Run once in Supabase SQL Editor AFTER store-access.sql. Safe to run again.
-- A store manager can add an opening for their own store and see their store's openings.
-- They still can't read or change anything else in public.openings.

create or replace function public.submit_opening(pos text, need int default 1, otype text default null, oshift text default null, onote text default null, who text default null)
returns text
language plpgsql security definer set search_path = public as $$
declare
  st  text := public.my_store();
  w   text := coalesce(nullif(who, ''), lower(auth.jwt() ->> 'email'));
  ms  bigint := floor(extract(epoch from clock_timestamp()) * 1000)::bigint;
  oid text := 'o' || to_hex(ms) || substr(md5(random()::text), 1, 4);
begin
  if st is null then raise exception 'Only store managers can request openings'; end if;
  if coalesce(trim(pos), '') = '' or length(pos) > 80 then raise exception 'Enter the position'; end if;
  insert into public.openings (id, data) values (oid, jsonb_build_object(
    'store', st, 'position', trim(pos), 'needed', greatest(1, least(coalesce(need, 1), 50)),
    'type', coalesce(left(otype, 40), ''), 'shift', coalesce(left(oshift, 40), ''), 'notes', coalesce(left(onote, 500), ''),
    'fromStore', true, 'requestedBy', w, 'createdAt', ms, 'updatedAt', ms));
  return oid;
end $$;
revoke all on function public.submit_opening(text, int, text, text, text, text) from public, anon;
grant execute on function public.submit_opening(text, int, text, text, text, text) to authenticated;

drop function if exists public.store_openings();
create function public.store_openings()
returns table (id text, pos_name text, needed int, otype text, oshift text, notes text, requested_by text, created_ms bigint, from_store boolean)
language sql stable security definer set search_path = public as $$
  select o.id, o.data->>'position', coalesce((o.data->>'needed')::int, 1), o.data->>'type', o.data->>'shift',
         o.data->>'notes', o.data->>'requestedBy', (o.data->>'createdAt')::bigint,
         coalesce((o.data->>'fromStore')::boolean, false)
  from public.openings o
  where o.data->>'store' = public.my_store()
  order by (o.data->>'createdAt')::bigint desc nulls last;
$$;
revoke all on function public.store_openings() from public, anon;
grant execute on function public.store_openings() to authenticated;

-- A store can edit or remove only the openings its own store requested (not ones the office added).
create or replace function public.update_store_opening(oid text, pos text, need int default 1, otype text default null, oshift text default null, onote text default null, who text default null)
returns boolean
language plpgsql security definer set search_path = public as $$
declare
  st text := public.my_store();
  w  text := coalesce(nullif(who, ''), lower(auth.jwt() ->> 'email'));
  ms bigint := floor(extract(epoch from clock_timestamp()) * 1000)::bigint;
begin
  if st is null then raise exception 'Only store managers can edit store requests'; end if;
  if coalesce(trim(pos), '') = '' or length(pos) > 80 then raise exception 'Enter the position'; end if;
  update public.openings
     set data = data || jsonb_build_object('position', trim(pos), 'needed', greatest(1, least(coalesce(need, 1), 50)),
                  'type', coalesce(left(otype, 40), ''), 'shift', coalesce(left(oshift, 40), ''), 'notes', coalesce(left(onote, 500), ''),
                  'updatedAt', ms, 'editedBy', w),
         updated_at = now()
   where id = oid and data->>'store' = st and coalesce((data->>'fromStore')::boolean, false);
  if not found then raise exception 'You can only edit positions your store requested'; end if;
  return true;
end $$;
revoke all on function public.update_store_opening(text, text, int, text, text, text, text) from public, anon;
grant execute on function public.update_store_opening(text, text, int, text, text, text, text) to authenticated;

create or replace function public.remove_store_opening(oid text)
returns boolean
language plpgsql security definer set search_path = public as $$
declare st text := public.my_store();
begin
  if st is null then raise exception 'Only store managers can remove store requests'; end if;
  delete from public.openings where id = oid and data->>'store' = st and coalesce((data->>'fromStore')::boolean, false);
  if not found then raise exception 'You can only remove positions your store requested'; end if;
  return true;
end $$;
revoke all on function public.remove_store_opening(text) from public, anon;
grant execute on function public.remove_store_opening(text) to authenticated;

-- Stores can pass on an applicant. It leaves their list and the office sees who passed and why.
alter table public.shares
  add column if not exists declined_at    timestamptz,
  add column if not exists declined_by    text,
  add column if not exists decline_reason text;

create or replace function public.decline_applicant(cid text, reason text default null, who text default null)
returns boolean
language plpgsql security definer set search_path = public as $$
declare
  st text := public.my_store();
  w  text := coalesce(nullif(who, ''), lower(auth.jwt() ->> 'email'));
  ms bigint := floor(extract(epoch from clock_timestamp()) * 1000)::bigint;
  rs text := nullif(left(trim(coalesce(reason, '')), 500), '');
begin
  if st is null then raise exception 'Only store managers can pass on applicants'; end if;
  if exists (select 1 from public.hire_requests where candidate_id = cid and store = st and status in ('pending','approved')) then
    raise exception 'Cancel the hire request first';
  end if;
  update public.shares
     set declined_at = now(), declined_by = w, decline_reason = rs, claimed_at = null, claimed_by = null
   where candidate_id = cid and store = st and declined_at is null;
  if not found then raise exception 'This applicant is not on your list'; end if;
  update public.candidates
     set data = data || jsonb_build_object('notesLog', coalesce(data -> 'notesLog', '[]'::jsonb) || jsonb_build_array(jsonb_build_object(
           'id', 'n' || ms::text, 'text', st || ' passed' || coalesce(': ' || rs, '.'), 'at', ms, 'by', w))),
         updated_at = now()
   where id = cid;
  return true;
end $$;
revoke all on function public.decline_applicant(text, text, text) from public, anon;
grant execute on function public.decline_applicant(text, text, text) to authenticated;

-- Claim ignores stores that passed, and keeps their "passed" record.
create or replace function public.claim_applicant(cid text, who text default null)
returns boolean
language plpgsql security definer set search_path = public as $$
declare st text := public.my_store();
begin
  if st is null then raise exception 'Only store managers can claim applicants'; end if;
  if not exists (select 1 from public.shares where candidate_id = cid and store = st and declined_at is null) then
    raise exception 'This applicant is not shared with your store';
  end if;
  if exists (select 1 from public.shares where candidate_id = cid and store <> st and claimed_at is not null) then
    raise exception 'Another store already claimed this applicant';
  end if;
  update public.shares set claimed_at = coalesce(claimed_at, now()), claimed_by = coalesce(claimed_by, who, lower(auth.jwt() ->> 'email'))
   where candidate_id = cid and store = st;
  delete from public.shares where candidate_id = cid and store <> st and declined_at is null;
  update public.candidates
     set data = jsonb_set(data, '{store}', to_jsonb(st)), updated_at = now()
   where id = cid;
  return true;
end $$;

-- "No show / no reply" is no longer a stage: move those applicants to Not moving forward with that reason.
update public.candidates
   set data = data || jsonb_build_object('stage', 'declined', 'closeReason', coalesce(nullif(data->>'closeReason', ''), 'Didn’t reply / no answer')),
       updated_at = now()
 where data->>'stage' = 'noshow';

-- Interviews: the store asks for an in-person interview with 1–3 times that work, the office confirms one
-- with the applicant. Or the store books it itself. Afterward the store reports showed / no show.
create table if not exists public.interview_requests (
  id              uuid primary key default gen_random_uuid(),
  candidate_id    text not null references public.candidates(id) on delete cascade,
  store           text not null,
  requested_by    text,
  requested_email text not null default lower(auth.jwt() ->> 'email'),
  slots           jsonb not null default '[]'::jsonb,
  ask_for         text,
  note            text,
  status          text not null default 'pending' check (status in ('pending','scheduled','cancelled')),
  self_scheduled  boolean not null default false,
  scheduled_at    text,
  scheduled_by    text,
  scheduled_on    timestamptz,
  outcome         text check (outcome in ('showed','noshow')),
  outcome_by      text,
  outcome_at      timestamptz,
  created_at      timestamptz not null default now()
);
alter table public.interview_requests enable row level security;
revoke all on public.interview_requests from anon;
grant select, insert, update, delete on public.interview_requests to authenticated;
drop policy if exists "interviews read"   on public.interview_requests;
drop policy if exists "interviews office" on public.interview_requests;
drop policy if exists "interviews cancel" on public.interview_requests;
create policy "interviews read"   on public.interview_requests for select to authenticated using (public.is_staff() or store = public.my_store());
create policy "interviews office" on public.interview_requests for all    to authenticated using (public.is_staff()) with check (public.is_staff());
create policy "interviews cancel" on public.interview_requests for update to authenticated
  using (store = public.my_store() and status = 'pending') with check (store = public.my_store() and status = 'cancelled');
do $$ begin
  begin alter publication supabase_realtime add table public.interview_requests; exception when duplicate_object then null; end;
end $$;

create or replace function public.request_interview(cid text, slots text[], ask text default null, inote text default null, who text default null)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  st text := public.my_store();
  w  text := coalesce(nullif(who, ''), lower(auth.jwt() ->> 'email'));
  s  text;
  ok text[] := '{}';
  rid uuid;
begin
  if st is null then raise exception 'Only store managers can request interviews'; end if;
  if not exists (select 1 from public.shares where candidate_id = cid and store = st and claimed_at is not null and declined_at is null) then
    raise exception 'Claim this applicant first';
  end if;
  foreach s in array coalesce(slots, '{}') loop
    if s ~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$' then ok := ok || s; end if;
  end loop;
  if array_length(ok, 1) is null then raise exception 'Add at least one time that works'; end if;
  update public.interview_requests set status = 'cancelled' where candidate_id = cid and store = st and status = 'pending';
  insert into public.interview_requests (candidate_id, store, requested_by, slots, ask_for, note)
  values (cid, st, w, to_jsonb(ok[1:3]), nullif(left(trim(coalesce(ask, '')), 120), ''), nullif(left(trim(coalesce(inote, '')), 500), ''))
  returning id into rid;
  return rid;
end $$;
revoke all on function public.request_interview(text, text[], text, text, text) from public, anon;
grant execute on function public.request_interview(text, text[], text, text, text) to authenticated;

create or replace function public.store_schedule_interview(cid text, at text, ask text default null, inote text default null, who text default null)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  st text := public.my_store();
  w  text := coalesce(nullif(who, ''), lower(auth.jwt() ->> 'email'));
  ms bigint := floor(extract(epoch from clock_timestamp()) * 1000)::bigint;
  rid uuid;
begin
  if st is null then raise exception 'Only store managers can schedule interviews'; end if;
  if not exists (select 1 from public.shares where candidate_id = cid and store = st and claimed_at is not null and declined_at is null) then
    raise exception 'Claim this applicant first';
  end if;
  if at is null or at !~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$' then raise exception 'Pick the interview date and time'; end if;
  update public.interview_requests set status = 'cancelled' where candidate_id = cid and store = st and status = 'pending';
  insert into public.interview_requests (candidate_id, store, requested_by, slots, ask_for, note, status, self_scheduled, scheduled_at, scheduled_by, scheduled_on)
  values (cid, st, w, to_jsonb(array[at]), nullif(left(trim(coalesce(ask, '')), 120), ''), nullif(left(trim(coalesce(inote, '')), 500), ''), 'scheduled', true, at, w, now())
  returning id into rid;
  update public.candidates
     set data = data || jsonb_build_object(
           'stage', case when data->>'stage' in ('new','screen') then 'interview' else data->>'stage' end,
           'history', case when data->>'stage' in ('new','screen')
                           then coalesce(data->'history','[]'::jsonb) || jsonb_build_array(jsonb_build_object('stage','interview','at',ms))
                           else coalesce(data->'history','[]'::jsonb) end,
           'interviewDate', at, 'store', st,
           'notesLog', coalesce(data->'notesLog','[]'::jsonb) || jsonb_build_array(jsonb_build_object(
              'id', 'n' || ms::text, 'at', ms, 'by', w,
              'text', st || ' scheduled an in-person interview: ' || to_char(at::timestamp, 'Dy Mon FMDD "at" FMHH12:MI AM') ||
                      coalesce(' — ' || nullif(trim(coalesce(inote, '')), ''), '')))),
         updated_at = now()
   where id = cid;
  return rid;
end $$;
revoke all on function public.store_schedule_interview(text, text, text, text, text) from public, anon;
grant execute on function public.store_schedule_interview(text, text, text, text, text) to authenticated;

create or replace function public.interview_outcome(rid uuid, res text, who text default null)
returns boolean
language plpgsql security definer set search_path = public as $$
declare
  st text := public.my_store();
  w  text := coalesce(nullif(who, ''), lower(auth.jwt() ->> 'email'));
  ms bigint := floor(extract(epoch from clock_timestamp()) * 1000)::bigint;
  r  public.interview_requests;
begin
  if st is null then raise exception 'Only store managers can report interviews'; end if;
  if res not in ('showed','noshow') then raise exception 'Bad outcome'; end if;
  select * into r from public.interview_requests where id = rid and store = st and status = 'scheduled';
  if not found then raise exception 'Interview not found'; end if;
  update public.interview_requests set outcome = res, outcome_by = w, outcome_at = now() where id = rid;
  if res = 'noshow' then
    update public.shares set declined_at = now(), declined_by = w, decline_reason = 'No show for interview', claimed_at = null, claimed_by = null
     where candidate_id = r.candidate_id and store = st;
    update public.candidates
       set data = data || jsonb_build_object('stage', 'declined', 'closeReason', 'No show',
             'history', coalesce(data->'history','[]'::jsonb) || jsonb_build_array(jsonb_build_object('stage','declined','at',ms)),
             'notesLog', coalesce(data->'notesLog','[]'::jsonb) || jsonb_build_array(jsonb_build_object(
                'id', 'n' || ms::text, 'at', ms, 'by', w, 'text', st || ': no show for the interview. Moved to Not moving forward.'))),
           updated_at = now()
     where id = r.candidate_id;
  else
    update public.candidates
       set data = data || jsonb_build_object('notesLog', coalesce(data->'notesLog','[]'::jsonb) || jsonb_build_array(jsonb_build_object(
                'id', 'n' || ms::text, 'at', ms, 'by', w, 'text', st || ': interview done.'))),
           updated_at = now()
     where id = r.candidate_id;
  end if;
  return true;
end $$;
revoke all on function public.interview_outcome(uuid, text, text) from public, anon;
grant execute on function public.interview_outcome(uuid, text, text) to authenticated;

-- Passing also cancels any open interview request from that store.
create or replace function public.decline_applicant(cid text, reason text default null, who text default null)
returns boolean
language plpgsql security definer set search_path = public as $$
declare
  st text := public.my_store();
  w  text := coalesce(nullif(who, ''), lower(auth.jwt() ->> 'email'));
  ms bigint := floor(extract(epoch from clock_timestamp()) * 1000)::bigint;
  rs text := nullif(left(trim(coalesce(reason, '')), 500), '');
begin
  if st is null then raise exception 'Only store managers can pass on applicants'; end if;
  if exists (select 1 from public.hire_requests where candidate_id = cid and store = st and status in ('pending','approved')) then
    raise exception 'Cancel the hire request first';
  end if;
  update public.shares
     set declined_at = now(), declined_by = w, decline_reason = rs, claimed_at = null, claimed_by = null
   where candidate_id = cid and store = st and declined_at is null;
  if not found then raise exception 'This applicant is not on your list'; end if;
  update public.interview_requests set status = 'cancelled' where candidate_id = cid and store = st and status = 'pending';
  update public.candidates
     set data = data || jsonb_build_object('notesLog', coalesce(data -> 'notesLog', '[]'::jsonb) || jsonb_build_array(jsonb_build_object(
           'id', 'n' || ms::text, 'text', st || ' passed' || coalesce(': ' || rs, '.'), 'at', ms, 'by', w))),
         updated_at = now()
   where id = cid;
  return true;
end $$;

-- Stores see when someone is hired and their first day (date and time only; never pay or office notes).
drop function if exists public.store_applicants();
create function public.store_applicants()
returns table (
  id text, name text, phone text, email text,
  position_wanted text, hire_for text, employment_type text, shift text,
  can_start text, availability text, avail_days jsonb, form_language text,
  shared_at timestamptz, claimed_at timestamptz, claimed_by text,
  is_hired boolean, first_day text, first_time text
)
language sql stable security definer set search_path = public as $$
  select c.id,
         c.data->>'name', c.data->>'phone', c.data->>'email',
         c.data->>'position', c.data->>'hireFor', c.data->>'employmentType', c.data->>'shift',
         c.data->>'startDate', c.data->>'availability', coalesce(c.data->'availDays','[]'::jsonb), c.data->>'formLanguage',
         s.shared_at, s.claimed_at, s.claimed_by,
         coalesce(c.data->>'stage', '') = 'hired',
         case when c.data->>'stage' in ('offer','hired') then nullif(c.data->>'offerStart', '') end,
         case when c.data->>'stage' in ('offer','hired') then nullif(c.data->>'offerStartTime', '') end
  from public.shares s
  join public.candidates c on c.id = s.candidate_id
  where s.store = public.my_store() and s.declined_at is null
  order by s.shared_at desc;
$$;
revoke all on function public.store_applicants() from public, anon;
grant execute on function public.store_applicants() to authenticated;
