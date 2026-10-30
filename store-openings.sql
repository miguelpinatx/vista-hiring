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

create or replace function public.store_openings()
returns table (id text, pos_name text, needed int, otype text, oshift text, notes text, requested_by text, created_ms bigint)
language sql stable security definer set search_path = public as $$
  select o.id, o.data->>'position', coalesce((o.data->>'needed')::int, 1), o.data->>'type', o.data->>'shift',
         o.data->>'notes', o.data->>'requestedBy', (o.data->>'createdAt')::bigint
  from public.openings o
  where o.data->>'store' = public.my_store()
  order by (o.data->>'createdAt')::bigint desc nulls last;
$$;
revoke all on function public.store_openings() from public, anon;
grant execute on function public.store_openings() to authenticated;
