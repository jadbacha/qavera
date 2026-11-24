-- QAVERA: order times (website, admin).
--   Delivery: any hour from 12 PM to 10 PM, every day.
--   Pickup: shop hours, 10 AM to 8 PM (Fridays 1 PM to 5 PM).
--   Website orders: at least 2 hours after ordering (order at 11 AM -> from 1 PM;
--   at 8:30 PM -> tomorrow). Chocolate Bonbons boxes can be same day too.
--   Admin (phone / WhatsApp) orders: the same hours, no 2-hour notice; older
--   orders keep their time window.
-- Paste into Supabase SQL Editor and click Run. Safe to run more than once.

begin;

do $patch$
declare
  r record;
  v_def text;
  v_new text;
begin
  -- 1. Website checkout
  for r in select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname = 'create_qavera_order'
  loop
    v_def := pg_get_functiondef(r.oid);
    continue when position('v_slot_hour' in v_def) > 0;  -- already done
    if position($q1$  v_has_box boolean := false;
$q1$ in v_def) = 0 or position($q2$  if v_pickup and extract(isodow from p_scheduled_date) = 5 then
    if coalesce(p_time_slot, '') <> '13:00-18:00' then
      raise exception 'On Fridays pickup is 1 PM – 6 PM';
    end if;
  elsif v_pickup and coalesce(p_time_slot, '') not in ('10:00-14:00', '16:00-21:00') then
    raise exception 'Please choose a pickup time: 10 AM – 2 PM or 4 PM – 9 PM';
  end if;
  if not v_pickup and coalesce(p_time_slot, '') not in ('12:00-16:00', '18:00-23:00') then
    raise exception 'Please choose a delivery time: 12 PM – 4 PM or 6 PM – 11 PM';
  end if;
$q2$ in v_def) = 0
       or position($q3$  -- Boxes are made to order: from tomorrow.
  if v_has_box and p_scheduled_date < v_today + 1 then
    raise exception 'Premium and Luxury boxes are made to order. The earliest date is tomorrow.';
  end if;
$q3$ in v_def) = 0 or position($q4$  -- Same day: a time slot can be chosen until 1 hour before it starts.
  if p_scheduled_date = v_today
     and v_now_time >= (case p_time_slot
                          when '10:00-14:00' then time '09:00'
                          when '12:00-16:00' then time '11:00'
                          when '13:00-18:00' then time '12:00'
                          when '16:00-21:00' then time '15:00'
                          else time '17:00' end) then
    raise exception 'This time is no longer available today. Please choose a later time or another day.';
  end if;
$q4$ in v_def) = 0 then
      raise exception 'create_qavera_order is not the expected version: send this message to Claude';
    end if;
    v_new := replace(v_def, $q1$  v_has_box boolean := false;
$q1$, $n1$  v_has_box boolean := false;
  v_slot_hour integer;
$n1$);
    v_new := replace(v_new, $q2$  if v_pickup and extract(isodow from p_scheduled_date) = 5 then
    if coalesce(p_time_slot, '') <> '13:00-18:00' then
      raise exception 'On Fridays pickup is 1 PM – 6 PM';
    end if;
  elsif v_pickup and coalesce(p_time_slot, '') not in ('10:00-14:00', '16:00-21:00') then
    raise exception 'Please choose a pickup time: 10 AM – 2 PM or 4 PM – 9 PM';
  end if;
  if not v_pickup and coalesce(p_time_slot, '') not in ('12:00-16:00', '18:00-23:00') then
    raise exception 'Please choose a delivery time: 12 PM – 4 PM or 6 PM – 11 PM';
  end if;
$q2$, $n2$  -- Times (056): one hour each. Delivery 12 PM – 10 PM every day; pickup in
  -- shop hours, 10 AM – 8 PM (Fridays 1 PM – 5 PM).
  if coalesce(p_time_slot, '') !~ '^([01][0-9]|2[0-3]):00$' then
    raise exception 'Please choose a % time', case when v_pickup then 'pickup' else 'delivery' end;
  end if;
  v_slot_hour := split_part(p_time_slot, ':', 1)::integer;
  if v_pickup and extract(isodow from p_scheduled_date) = 5 and v_slot_hour not between 13 and 17 then
    raise exception 'On Fridays pickup is between 1 PM and 5 PM';
  elsif v_pickup and v_slot_hour not between 10 and 20 then
    raise exception 'Pickup is between 10 AM and 8 PM';
  elsif not v_pickup and v_slot_hour not between 12 and 22 then
    raise exception 'Delivery is between 12 PM and 10 PM';
  end if;
$n2$);
    v_new := replace(v_new, $q3$  -- Boxes are made to order: from tomorrow.
  if v_has_box and p_scheduled_date < v_today + 1 then
    raise exception 'Premium and Luxury boxes are made to order. The earliest date is tomorrow.';
  end if;
$q3$, $n3$  -- Boxes can be delivered the same day too (056).
$n3$);
    v_new := replace(v_new, $q4$  -- Same day: a time slot can be chosen until 1 hour before it starts.
  if p_scheduled_date = v_today
     and v_now_time >= (case p_time_slot
                          when '10:00-14:00' then time '09:00'
                          when '12:00-16:00' then time '11:00'
                          when '13:00-18:00' then time '12:00'
                          when '16:00-21:00' then time '15:00'
                          else time '17:00' end) then
    raise exception 'This time is no longer available today. Please choose a later time or another day.';
  end if;
$q4$, $n4$  -- At least 2 hours after ordering (056): an order at 8:30 PM is for tomorrow.
  if p_scheduled_date + make_time(v_slot_hour, 0, 0) < (now() at time zone 'Asia/Qatar') + interval '2 hours' then
    raise exception 'Please choose a time at least 2 hours from now.';
  end if;
$n4$);
    execute v_new;
  end loop;

  -- 2. Admin page: new and edited orders
  for r in select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname in ('admin_create_order', 'admin_update_order')
  loop
    v_def := pg_get_functiondef(r.oid);
    continue when position('Times (056)' in v_def) > 0;
    if position($q5$  if v_pickup and extract(isodow from p_scheduled_date) = 5 then
    if coalesce(p_time_slot, '') <> '13:00-18:00' then
      raise exception 'On Fridays pickup is 1 PM – 6 PM';
    end if;
  elsif v_pickup and coalesce(p_time_slot, '') not in ('10:00-14:00', '16:00-21:00') then
    raise exception 'Please choose a pickup time';
  elsif not v_pickup and coalesce(p_time_slot, '') not in ('12:00-16:00', '18:00-23:00') then
    raise exception 'Please choose a delivery time';
  end if;
$q5$ in v_def) = 0 then
      raise exception 'An admin order function is not the expected version: send this message to Claude';
    end if;
    execute replace(v_def, $q5$  if v_pickup and extract(isodow from p_scheduled_date) = 5 then
    if coalesce(p_time_slot, '') <> '13:00-18:00' then
      raise exception 'On Fridays pickup is 1 PM – 6 PM';
    end if;
  elsif v_pickup and coalesce(p_time_slot, '') not in ('10:00-14:00', '16:00-21:00') then
    raise exception 'Please choose a pickup time';
  elsif not v_pickup and coalesce(p_time_slot, '') not in ('12:00-16:00', '18:00-23:00') then
    raise exception 'Please choose a delivery time';
  end if;
$q5$, $n5$  -- Times (056): one hour each ("13:00"); older orders keep their time window.
  if coalesce(p_time_slot, '') not in ('12:00-16:00', '18:00-23:00', '10:00-14:00', '16:00-21:00', '13:00-18:00')
     and coalesce(p_time_slot, '') !~ '^([01][0-9]|2[0-3]):00$' then
    raise exception 'Please choose a % time', case when v_pickup then 'pickup' else 'delivery' end;
  end if;
$n5$);
  end loop;
end
$patch$;

commit;

-- Check: should say "ok" three times.
select p.proname,
       case when pg_get_functiondef(p.oid) like '%(056)%' then 'ok' else 'NOT UPDATED' end as status
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname in ('create_qavera_order', 'admin_create_order', 'admin_update_order');
