-- Vista Hiring Tracker: position request link for store managers (no sign-in)
-- Run once in Supabase SQL Editor. Safe to run again.
-- The link carries a secret code (settings key 'request_code', set from the Stores tab).
-- With the code, a store can add an opening; without it, nothing happens. Nobody can read data through it.

create or replace function public.request_link_info(p_code text)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare ok boolean; lst jsonb;
begin
  select (value->>'code') = p_code and length(coalesce(p_code, '')) >= 8 into ok from public.settings where key = 'request_code';
  if not coalesce(ok, false) then return jsonb_build_object('ok', false); end if;
  select value->'list' into lst from public.settings where key = 'stores';
  return jsonb_build_object('ok', true, 'stores',
    coalesce(lst, '["Montana","Doniphan","Central","Horizon","Piedras","Urban","Alameda","Commissary"]'::jsonb));
end $$;
revoke all on function public.request_link_info(text) from public;
grant execute on function public.request_link_info(text) to anon, authenticated;

create or replace function public.submit_position_request(p_code text, p_store text, p_who text, p_pos text,
  p_need int default 1, p_type text default null, p_shift text default null, p_note text default null)
returns text
language plpgsql security definer set search_path = public as $$
declare
  info jsonb := public.request_link_info(p_code);
  ms   bigint := floor(extract(epoch from clock_timestamp()) * 1000)::bigint;
  oid  text := 'o' || to_hex(ms) || substr(md5(random()::text), 1, 4);
begin
  if not coalesce((info->>'ok')::boolean, false) then raise exception 'This link is no longer valid'; end if;
  if not (info->'stores') ? p_store then raise exception 'Pick your store'; end if;
  if coalesce(trim(p_who), '') = '' or length(p_who) > 80 then raise exception 'Enter your name'; end if;
  if coalesce(trim(p_pos), '') = '' or length(p_pos) > 80 then raise exception 'Enter the position'; end if;
  if (select count(*) from public.openings where data->>'store' = p_store and (data->>'viaLink')::boolean
        and (data->>'createdAt')::bigint > ms - 3600000) >= 15 then
    raise exception 'Too many requests from this store in the last hour';
  end if;
  insert into public.openings (id, data) values (oid, jsonb_build_object(
    'store', p_store, 'position', trim(p_pos), 'needed', greatest(1, least(coalesce(p_need, 1), 50)),
    'type', coalesce(left(p_type, 40), ''), 'shift', coalesce(left(p_shift, 40), ''), 'notes', coalesce(left(p_note, 500), ''),
    'fromStore', true, 'viaLink', true, 'requestedBy', left(trim(p_who), 80), 'createdAt', ms, 'updatedAt', ms));
  return oid;
end $$;
revoke all on function public.submit_position_request(text, text, text, text, int, text, text, text) from public;
grant execute on function public.submit_position_request(text, text, text, text, int, text, text, text) to anon, authenticated;
