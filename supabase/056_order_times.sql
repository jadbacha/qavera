-- QAVERA: order times (website, admin).
--   Delivery: any hour from 12 PM to 10 PM, every day.
--   Pickup: shop hours, 10 AM to 8 PM (Fridays 1 PM to 5 PM).
--   Website orders: at least 2 hours after ordering (order at 11 AM -> from 1 PM;
--   at 8:30 PM -> tomorrow). Chocolate Bonbons boxes can be same day too.
--   Admin (phone / WhatsApp) orders: the same hours, no 2-hour notice; older
--   orders keep their time window.
-- Finds the parts to change by pattern, so small wording differences don't matter.
-- Paste into Supabase SQL Editor and click Run. Safe to run more than once.

begin;

do $patch$
declare
  r record;
  v_def text;
  v_new text;
  v_step text;
  -- The old time checks (pickup / Friday / delivery windows), up to the delivery one.
  p_times constant text := $r$if\s+v_pickup\s+and\s+extract\s*\(\s*isodow\s+from\s+p_scheduled_date\s*\)\s*=\s*5\s+then.*?'18:00-23:00'\s*\)\s*then\s+raise\s+exception\s+'[^']*'[^;]*;\s*end\s+if\s*;$r$;
  p_box constant text := $r$if\s+v_has_box\s+and\s+p_scheduled_date\s*<\s*v_today\s*\+\s*1\s+then\s+raise\s+exception\s+'[^']*'[^;]*;\s*end\s+if\s*;$r$;
  p_same_day constant text := $r$if\s+p_scheduled_date\s*=\s*v_today\s+and[^;]*\s+then\s+raise\s+exception\s+'[^']*'[^;]*;\s*end\s+if\s*;$r$;
  new_times constant text := $n$-- Times (056): one hour each. Delivery 12 PM - 10 PM every day; pickup in
  -- shop hours, 10 AM - 8 PM (Fridays 1 PM - 5 PM); at least 2 hours after ordering.
  if coalesce(p_time_slot, '') !~ '^([01][0-9]|2[0-3]):00$' then
    raise exception 'Please choose a % time', case when v_pickup then 'pickup' else 'delivery' end;
  end if;
  if v_pickup and extract(isodow from p_scheduled_date) = 5
     and split_part(p_time_slot, ':', 1)::integer not between 13 and 17 then
    raise exception 'On Fridays pickup is between 1 PM and 5 PM';
  elsif v_pickup and split_part(p_time_slot, ':', 1)::integer not between 10 and 20 then
    raise exception 'Pickup is between 10 AM and 8 PM';
  elsif not v_pickup and split_part(p_time_slot, ':', 1)::integer not between 12 and 22 then
    raise exception 'Delivery is between 12 PM and 10 PM';
  end if;
  if p_scheduled_date + make_time(split_part(p_time_slot, ':', 1)::integer, 0, 0)
     < (now() at time zone 'Asia/Qatar') + interval '2 hours' then
    raise exception 'Please choose a time at least 2 hours from now.';
  end if;$n$;
  admin_times constant text := $n$-- Times (056): one hour each ("13:00"); older orders keep their time window.
  if coalesce(p_time_slot, '') not in ('12:00-16:00', '18:00-23:00', '10:00-14:00', '16:00-21:00', '13:00-18:00')
     and coalesce(p_time_slot, '') !~ '^([01][0-9]|2[0-3]):00$' then
    raise exception 'Please choose a % time', case when v_pickup then 'pickup' else 'delivery' end;
  end if;$n$;
begin
  -- 1. Website checkout
  for r in select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname = 'create_qavera_order'
  loop
    v_def := pg_get_functiondef(r.oid);
    continue when position('Times (056)' in v_def) > 0;  -- already done

    v_step := 'the time checks';
    v_new := regexp_replace(v_def, p_times, new_times);
    if v_new = v_def then
      raise exception 'Could not find % in create_qavera_order: send this message to Claude', v_step;
    end if;

    -- The old same-day cut-off (by time window): replaced by the 2-hour rule above.
    v_def := v_new;
    v_new := regexp_replace(v_def, p_same_day, '-- Same-day cut-off: the 2-hour rule above (056).');
    if v_new = v_def then
      raise exception 'Could not find the same-day check in create_qavera_order: send this message to Claude';
    end if;

    -- Boxes made to order "from tomorrow": now same day too (skipped if already gone).
    v_new := regexp_replace(v_new, p_box, '-- Boxes can be delivered the same day too (056).');

    execute v_new;
  end loop;

  -- 2. Admin page: new and edited orders
  for r in select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname in ('admin_create_order', 'admin_update_order')
  loop
    v_def := pg_get_functiondef(r.oid);
    continue when position('Times (056)' in v_def) > 0;
    v_new := regexp_replace(v_def, p_times, admin_times);
    if v_new = v_def then
      raise exception 'Could not find the time checks in %: send this message to Claude', (select proname from pg_proc where oid = r.oid);
    end if;
    execute v_new;
  end loop;
end
$patch$;

commit;

-- Check: should say "ok" three times.
select p.proname,
       case when pg_get_functiondef(p.oid) like '%(056)%' then 'ok' else 'NOT UPDATED' end as status
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname in ('create_qavera_order', 'admin_create_order', 'admin_update_order');
