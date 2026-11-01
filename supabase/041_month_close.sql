-- QAVERA: month close (till "Day close" tab → Month; admin page Day close → Month).
--   The whole month: sales by payment method (counted on the day the money
--   comes in, like the day close), every cash out, and a line per day with
--   its sales, cash into the drawer, cash out and the saved day close.
--   Admins only. Paste into Supabase SQL Editor and click Run. Safe to run more than once.

-- Money that came in between two times, one row per order (internal helper).
create or replace function public.qavera_money_in(p_from timestamptz, p_to timestamptz)
 returns table(day date, line text, total numeric)
 language sql
 stable
 security definer
 set search_path to 'public'
as $function$
  select (case when o.source = 'store' then o.created_at
               when o.payment_method in ('cash_on_delivery', 'card_on_delivery') then o.delivered_at
               else o.paid_at end at time zone 'Asia/Qatar')::date,
         case
           when o.source = 'store' then case when o.payment_method = 'cash' then 'shop_cash' else 'shop_card' end
           when o.payment_method = 'cash_on_delivery' then case when o.fulfillment_type = 'pickup' then 'cash_on_pickup' else 'cash_on_delivery' end
           when o.payment_method = 'card_on_delivery' then case when o.fulfillment_type = 'pickup' then 'card_on_pickup' else 'card_on_delivery' end
           else o.payment_method
         end,
         o.total
  from public.orders o
  where o.status <> 'cancelled'
    and (
      (o.source = 'store' and o.created_at >= p_from and o.created_at < p_to)
      or (o.source <> 'store' and o.payment_method in ('cash_on_delivery', 'card_on_delivery')
          and o.delivered_at >= p_from and o.delivered_at < p_to)
      or (o.source <> 'store' and o.payment_method in ('fawran', 'card_online')
          and o.paid_at >= p_from and o.paid_at < p_to)
    );
$function$;
revoke execute on function public.qavera_money_in(timestamptz, timestamptz) from public, anon, authenticated;

create or replace function public.month_report(p_month date)
 returns jsonb
 language plpgsql
 stable
 security definer
 set search_path to 'public'
as $function$
declare
  v_first date := date_trunc('month', p_month)::date;
  v_next date := (date_trunc('month', p_month) + interval '1 month')::date;
  v_from timestamptz := v_first::timestamp at time zone 'Asia/Qatar';
  v_to timestamptz := v_next::timestamp at time zone 'Asia/Qatar';
  v_lines jsonb;
  v_days jsonb;
  v_cash_out jsonb;
  v_cash_out_total numeric;
  v_total numeric;
  v_drawer numeric;
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'Only QAVERA admins can see the month close';
  end if;

  select coalesce(jsonb_object_agg(line, jsonb_build_object('count', n, 'total', t)), '{}'::jsonb),
         coalesce(sum(t), 0)
    into v_lines, v_total
  from (select line, count(*) as n, sum(total) as t from public.qavera_money_in(v_from, v_to) group by line) g;
  select coalesce(sum(total), 0) into v_drawer from public.qavera_money_in(v_from, v_to) where line in ('shop_cash', 'cash_on_pickup');

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', m.id, 'day', m.day, 'amount', m.amount, 'reason', m.reason, 'created_at', m.created_at,
           'by', coalesce(nullif(trim(p.full_name), ''), p.email, '')) order by m.day, m.created_at), '[]'::jsonb),
         coalesce(sum(m.amount), 0)
    into v_cash_out, v_cash_out_total
  from public.cash_movements m
  left join public.profiles p on p.id = m.created_by
  where m.day >= v_first and m.day < v_next;

  -- One line per day that had sales, cash out or a close.
  select coalesce(jsonb_agg(jsonb_build_object(
           'day', d.day,
           'total_sales', coalesce(s.total, 0),
           'orders', coalesce(s.n, 0),
           'drawer_cash_in', coalesce(s.drawer, 0),
           'cash_out', coalesce(c.amount, 0),
           'closed', k.day is not null,
           'opening_cash', k.opening_cash,
           'expected_cash', k.expected_cash,
           'counted_cash', k.counted_cash,
           'difference', k.difference) order by d.day), '[]'::jsonb)
    into v_days
  from (select day from public.qavera_money_in(v_from, v_to)
        union select day from public.cash_movements where day >= v_first and day < v_next
        union select day from public.day_closings where day >= v_first and day < v_next) d
  left join (select day, count(*) as n, sum(total) as total,
                    sum(total) filter (where line in ('shop_cash', 'cash_on_pickup')) as drawer
             from public.qavera_money_in(v_from, v_to) group by day) s on s.day = d.day
  left join (select day, sum(amount) as amount from public.cash_movements
             where day >= v_first and day < v_next group by day) c on c.day = d.day
  left join public.day_closings k on k.day = d.day;

  return jsonb_build_object(
    'month', v_first,
    'lines', v_lines,
    'total_sales', v_total,
    'drawer_cash_in', v_drawer,
    'cash_out', v_cash_out,
    'cash_out_total', v_cash_out_total,
    'days', v_days,
    'days_closed', (select count(*) from public.day_closings where day >= v_first and day < v_next),
    'difference_total', (select coalesce(sum(difference), 0) from public.day_closings where day >= v_first and day < v_next)
  );
end;
$function$;

revoke execute on function public.month_report(date) from public, anon;
grant execute on function public.month_report(date) to authenticated;
