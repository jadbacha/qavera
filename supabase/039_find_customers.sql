-- QAVERA: find a returning customer by phone or name (admin page and till).
--   Customers are saved automatically: every order already keeps the name
--   and phone (website, admin page and till). This looks them up, newest
--   first, with the last delivery address for delivery orders.
--   Only admins and shop staff can use it.
-- Paste into Supabase SQL Editor and click Run. Safe to run more than once.

create or replace function public.find_customers(p_query text, p_limit integer default 8)
 returns table(customer_name text, customer_phone text, delivery_area text, delivery_address text, last_order timestamptz, order_count integer)
 language plpgsql
 stable
 security definer
 set search_path to 'public'
as $function$
declare
  v_query text := trim(coalesce(p_query, ''));
  v_digits text := regexp_replace(coalesce(p_query, ''), '\D', '', 'g');
begin
  if not public.is_store_staff() then
    raise exception 'Only QAVERA staff can look up customers';
  end if;
  -- At least 3 digits of a phone number, or 2 letters of a name.
  if length(v_digits) < 3 and length(v_query) < 2 then
    return;
  end if;

  return query
  with o as (
    select o.customer_name, o.customer_phone, o.fulfillment_type, o.delivery_area, o.delivery_address, o.created_at,
           -- same person whether the phone was typed +974 5555 5555 or 55555555
           case when regexp_replace(o.customer_phone, '\D', '', 'g') ~ '^974[0-9]{8}$'
                then substr(regexp_replace(o.customer_phone, '\D', '', 'g'), 4)
                else regexp_replace(o.customer_phone, '\D', '', 'g') end as phone_key
    from public.orders o
    where o.status <> 'cancelled'
      and length(regexp_replace(coalesce(o.customer_phone, ''), '\D', '', 'g')) >= 6
      and nullif(trim(o.customer_name), '') is not null
      and lower(trim(o.customer_name)) <> 'walk-in customer'
  ),
  matched as (
    select distinct o.phone_key from o
    where (length(v_digits) >= 3 and regexp_replace(o.customer_phone, '\D', '', 'g') like '%' || v_digits || '%')
       or (length(v_query) >= 2 and o.customer_name ilike '%' || v_query || '%')
  ),
  latest as (
    select distinct on (o.phone_key) o.phone_key, o.customer_name, o.customer_phone, o.created_at
    from o join matched m using (phone_key)
    order by o.phone_key, o.created_at desc
  ),
  last_delivery as (
    select distinct on (o.phone_key) o.phone_key, o.delivery_area, o.delivery_address
    from o join matched m using (phone_key)
    where o.fulfillment_type = 'delivery' and nullif(trim(o.delivery_area), '') is not null
    order by o.phone_key, o.created_at desc
  ),
  counts as (
    select o.phone_key, count(*)::integer as n from o join matched m using (phone_key) group by o.phone_key
  )
  select l.customer_name, l.customer_phone, d.delivery_area, d.delivery_address, l.created_at, c.n
  from latest l
  left join last_delivery d using (phone_key)
  join counts c using (phone_key)
  order by l.created_at desc
  limit least(greatest(coalesce(p_limit, 8), 1), 20);
end;
$function$;

revoke execute on function public.find_customers(text, integer) from public, anon;
grant execute on function public.find_customers(text, integer) to authenticated;
