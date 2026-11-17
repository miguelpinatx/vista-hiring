-- Simple store portal (Nov 2026): store decides to hire with the first day they discussed,
-- marks Food Handler / TABC copies collected, and can add walk-in hires for office review.
-- Safe to re-run.

alter table public.hire_requests
  add column if not exists fh_collected   boolean not null default false,
  add column if not exists tabc_collected boolean not null default false,
  add column if not exists walkin         boolean not null default false;

-- Store decides to hire a claimed applicant. Replaces any open request from the same store.
create or replace function public.store_hire(cid text, pos text, sdate date, stime text default null,
                                             fh boolean default false, tabc boolean default false,
                                             hnote text default null, who text default null)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  st text := public.my_store();
  w  text := coalesce(nullif(who, ''), lower(auth.jwt() ->> 'email'));
  ms bigint := floor(extract(epoch from clock_timestamp()) * 1000)::bigint;
  p  text := nullif(left(trim(coalesce(pos, '')), 80), '');
  t  text := nullif(trim(coalesce(stime, '')), '');
  n  text := nullif(left(trim(coalesce(hnote, '')), 500), '');
  rid uuid;
begin
  if st is null then raise exception 'Only store managers can hire'; end if;
  if not exists (select 1 from public.shares where candidate_id = cid and store = st and claimed_at is not null and declined_at is null) then
    raise exception 'Claim this applicant first';
  end if;
  if p is null then raise exception 'Enter the position'; end if;
  if sdate is null then raise exception 'Enter the first day you discussed'; end if;
  if t is not null and t !~ '^\d{2}:\d{2}$' then raise exception 'Bad start time'; end if;
  update public.hire_requests set status = 'cancelled' where candidate_id = cid and store = st and status = 'pending';
  insert into public.hire_requests (candidate_id, store, requested_by, position, start_date, start_time, note, fh_collected, tabc_collected)
  values (cid, st, w, p, sdate, t, n, coalesce(fh, false), coalesce(tabc, false))
  returning id into rid;
  update public.candidates
     set data = data || jsonb_build_object(
           'store', st,
           'hireFor', coalesce(nullif(data->>'hireFor', ''), p),
           'offerStart', to_char(sdate, 'YYYY-MM-DD'),
           'offerStartTime', coalesce(t, data->>'offerStartTime', ''),
           'fhHave', coalesce(fh, false) or coalesce((data->>'fhHave')::boolean, false),
           'tabcHave', coalesce(tabc, false) or coalesce((data->>'tabcHave')::boolean, false),
           'notesLog', coalesce(data->'notesLog','[]'::jsonb) || jsonb_build_array(jsonb_build_object(
              'id', 'n' || ms::text, 'at', ms, 'by', w,
              'text', st || ' wants to hire for ' || p || '. First day discussed: ' || to_char(sdate, 'Dy Mon FMDD') ||
                      coalesce(' at ' || to_char(t::time, 'FMHH12:MI AM'), '') ||
                      case when fh or tabc then '. Collected: ' || concat_ws(', ', case when fh then 'Food Handler' end, case when tabc then 'TABC' end) else '' end ||
                      coalesce(' — ' || n, '') || '.'))),
         updated_at = now()
   where id = cid;
  return rid;
end $$;
revoke all on function public.store_hire(text, text, date, text, boolean, boolean, text, text) from public, anon;
grant execute on function public.store_hire(text, text, date, text, boolean, boolean, text, text) to authenticated;

-- Store ticks Food Handler / TABC copies collected for anyone hired at their store.
create or replace function public.store_certs(cid text, fh boolean, tabc boolean, who text default null)
returns boolean
language plpgsql security definer set search_path = public as $$
declare
  st text := public.my_store();
  w  text := coalesce(nullif(who, ''), lower(auth.jwt() ->> 'email'));
  ms bigint := floor(extract(epoch from clock_timestamp()) * 1000)::bigint;
  c  public.candidates;
  ofh boolean; otabc boolean; msg text;
begin
  if st is null then raise exception 'Only store managers can update this'; end if;
  if not exists (select 1 from public.shares where candidate_id = cid and store = st and declined_at is null) then
    raise exception 'This applicant is not on your list';
  end if;
  select * into c from public.candidates where id = cid;
  if not (c.data->>'stage' in ('offer','hired') or exists (select 1 from public.hire_requests where candidate_id = cid and store = st and status in ('pending','approved'))) then
    raise exception 'Only for hires';
  end if;
  ofh := coalesce((c.data->>'fhHave')::boolean, false); otabc := coalesce((c.data->>'tabcHave')::boolean, false);
  msg := concat_ws('; ',
    case when fh is not null and fh <> ofh then 'Food Handler copy ' || case when fh then 'collected' else 'unchecked' end end,
    case when tabc is not null and tabc <> otabc then 'TABC copy ' || case when tabc then 'collected' else 'unchecked' end end);
  if msg = '' then return true; end if;
  update public.candidates
     set data = data || jsonb_build_object('fhHave', coalesce(fh, ofh), 'tabcHave', coalesce(tabc, otabc),
           'notesLog', coalesce(data->'notesLog','[]'::jsonb) || jsonb_build_array(jsonb_build_object(
              'id', 'n' || ms::text, 'at', ms, 'by', w, 'text', st || ': ' || msg || '.'))),
         updated_at = now()
   where id = cid;
  update public.hire_requests set fh_collected = coalesce(fh, fh_collected), tabc_collected = coalesce(tabc, tabc_collected)
   where candidate_id = cid and store = st and status in ('pending','approved');
  return true;
end $$;
revoke all on function public.store_certs(text, boolean, boolean, text) from public, anon;
grant execute on function public.store_certs(text, boolean, boolean, text) to authenticated;

-- Walk-in the store already hired: creates the applicant, claims it for the store and sends a hire
-- request to the office for review. Limited to 25 a day per store.
create or replace function public.submit_walkin(wname text, wphone text, wemail text, wdept text, wapplied date,
                                                sdate date default null, stime text default null,
                                                fh boolean default false, tabc boolean default false,
                                                wnote text default null, wlang text default null, who text default null)
returns text
language plpgsql security definer set search_path = public as $$
declare
  st text := public.my_store();
  w  text := coalesce(nullif(who, ''), lower(auth.jwt() ->> 'email'));
  ms bigint := floor(extract(epoch from clock_timestamp()) * 1000)::bigint;
  nm text := nullif(left(trim(coalesce(wname, '')), 120), '');
  ph text := nullif(left(trim(coalesce(wphone, '')), 40), '');
  em text := nullif(lower(left(trim(coalesce(wemail, '')), 160)), '');
  dp text := nullif(left(trim(coalesce(wdept, '')), 80), '');
  t  text := nullif(trim(coalesce(stime, '')), '');
  n  text := nullif(left(trim(coalesce(wnote, '')), 500), '');
  appl bigint;
  cid text := 'w' || to_hex(ms) || substr(md5(random()::text), 1, 6);
begin
  if st is null then raise exception 'Only store managers can add walk-ins'; end if;
  if nm is null then raise exception 'Enter their name'; end if;
  if ph is null and em is null then raise exception 'Enter a phone number or email'; end if;
  if dp is null then raise exception 'Pick the department'; end if;
  if wapplied is null or wapplied > current_date + 1 or wapplied < current_date - 120 then raise exception 'Check the application date'; end if;
  if t is not null and t !~ '^\d{2}:\d{2}$' then raise exception 'Bad start time'; end if;
  if (select count(*) from public.hire_requests where store = st and walkin and created_at > now() - interval '1 day') >= 25 then
    raise exception 'Too many walk-ins today. Call the hiring office.';
  end if;
  appl := floor(extract(epoch from (wapplied::timestamp + interval '12 hours')) * 1000)::bigint;
  insert into public.candidates (id, data, updated_at) values (cid, jsonb_build_object(
      'name', nm, 'phone', coalesce(ph, ''), 'email', coalesce(em, ''),
      'position', dp, 'hireFor', dp, 'store', st, 'storeRaw', st,
      'stage', 'new', 'createdAt', appl, 'updatedAt', ms,
      'referralSource', 'Walk-in', 'referralDetail', 'Walk-in hired at ' || st,
      'formLanguage', coalesce(nullif(wlang, ''), 'English'),
      'walkin', true, 'interviewer', 'Miguel',
      'offerStart', coalesce(to_char(sdate, 'YYYY-MM-DD'), ''), 'offerStartTime', coalesce(t, ''),
      'fhHave', coalesce(fh, false), 'tabcHave', coalesce(tabc, false),
      'history', jsonb_build_array(jsonb_build_object('stage', 'new', 'at', appl)),
      'notesLog', jsonb_build_array(jsonb_build_object('id', 'n' || ms::text, 'at', ms, 'by', w,
        'text', 'Walk-in hired at ' || st || ' for ' || dp ||
                coalesce('. First day discussed: ' || to_char(sdate, 'Dy Mon FMDD') || coalesce(' at ' || to_char(t::time, 'FMHH12:MI AM'), ''), '') ||
                case when fh or tabc then '. Collected: ' || concat_ws(', ', case when fh then 'Food Handler' end, case when tabc then 'TABC' end) else '' end ||
                coalesce(' — ' || n, '') || '. Review and send the offer.'))
    ), now());
  insert into public.shares (candidate_id, store, shared_by, claimed_at, claimed_by) values (cid, st, w, now(), w);
  insert into public.hire_requests (candidate_id, store, requested_by, position, start_date, start_time, note, fh_collected, tabc_collected, walkin)
  values (cid, st, w, dp, sdate, t, coalesce('Walk-in. ' || n, 'Walk-in.'), coalesce(fh, false), coalesce(tabc, false), true);
  return cid;
end $$;
revoke all on function public.submit_walkin(text, text, text, text, date, date, text, boolean, boolean, text, text, text) from public, anon;
grant execute on function public.submit_walkin(text, text, text, text, date, date, text, boolean, boolean, text, text, text) to authenticated;

-- Store list now also returns stage, certs and walk-in flag (never pay or office notes).
drop function if exists public.store_applicants();
create function public.store_applicants()
returns table (
  id text, name text, phone text, email text,
  position_wanted text, hire_for text, employment_type text, shift text,
  can_start text, availability text, avail_days jsonb, form_language text,
  shared_at timestamptz, claimed_at timestamptz, claimed_by text,
  is_hired boolean, first_day text, first_time text,
  stage text, fh_have boolean, tabc_have boolean, fh_req text, tabc_req text, walkin boolean, applied_ms bigint
)
language sql stable security definer set search_path = public as $$
  select c.id,
         c.data->>'name', c.data->>'phone', c.data->>'email',
         c.data->>'position', c.data->>'hireFor', c.data->>'employmentType', c.data->>'shift',
         c.data->>'startDate', c.data->>'availability', coalesce(c.data->'availDays','[]'::jsonb), c.data->>'formLanguage',
         s.shared_at, s.claimed_at, s.claimed_by,
         coalesce(c.data->>'stage', '') = 'hired',
         nullif(c.data->>'offerStart', ''),
         nullif(c.data->>'offerStartTime', ''),
         case when c.data->>'stage' in ('offer','hired') then c.data->>'stage' else '' end,
         coalesce((c.data->>'fhHave')::boolean, false), coalesce((c.data->>'tabcHave')::boolean, false),
         coalesce(c.data->>'fhReq', 'auto'), coalesce(c.data->>'tabcReq', 'auto'),
         coalesce((c.data->>'walkin')::boolean, false),
         nullif(c.data->>'createdAt', '')::numeric::bigint
  from public.shares s
  join public.candidates c on c.id = s.candidate_id
  where s.store = public.my_store() and s.declined_at is null
  order by s.shared_at desc;
$$;
revoke all on function public.store_applicants() from public, anon;
grant execute on function public.store_applicants() to authenticated;
