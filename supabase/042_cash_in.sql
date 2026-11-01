-- QAVERA: cash in (money added to the drawer, e.g. change), next to cash out.
--   Cash in shows with a plus and is added to the expected cash in the drawer,
--   in the day close and the month close. Admins only.
-- Paste into Supabase SQL Editor and click Run. Safe to run more than once.

begin;

alter table public.cash_movements
  add column if not exists kind text not null default 'out';
alter table public.cash_movements drop constraint if exists cash_movements_kind_check;
alter table public.cash_movements add constraint cash_movements_kind_check check (kind in ('out', 'in'));

alter table public.day_closings
  add column if not exists cash_in numeric not null default 0;

create or replace function public.add_cash_in(p_day date, p_amount numeric, p_reason text)
 returns uuid
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_id uuid;
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'Only QAVERA admins can add cash';
  end if;
  if p_day is null or coalesce(p_amount, 0) <= 0 then
    raise exception 'Enter an amount';
  end if;
  if nullif(trim(p_reason), '') is null then
    raise exception 'Write what the cash is for';
  end if;
  insert into public.cash_movements (day, amount, reason, kind, created_by)
  values (p_day, round(p_amount, 2), left(trim(p_reason), 200), 'in', auth.uid())
  returning id into v_id;
  return v_id;
end;
$function$;

revoke execute on function public.add_cash_in(date, numeric, text) from public, anon;
grant execute on function public.add_cash_in(date, numeric, text) to authenticated;

create or replace function public.day_report(p_day date)
 returns jsonb
 language plpgsql
 stable
 security definer
 set search_path to 'public'
as $function$
declare
  v_from timestamptz := p_day::timestamp at time zone 'Asia/Qatar';
  v_to timestamptz := (p_day + 1)::timestamp at time zone 'Asia/Qatar';
  v_lines jsonb;
  v_cash_out jsonb;
  v_cash_out_total numeric;
  v_cash_in jsonb;
  v_cash_in_total numeric;
  v_prev record;
  v_close record;
  v_opening numeric;
  v_drawer_in numeric;
  v_total numeric;
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'Only QAVERA admins can see the day close';
  end if;

  -- Money that came in today, one line per way of paying.
  with money as (
    select case
             when o.source = 'store' then case when o.payment_method = 'cash' then 'shop_cash' else 'shop_card' end
             when o.payment_method = 'cash_on_delivery' then case when o.fulfillment_type = 'pickup' then 'cash_on_pickup' else 'cash_on_delivery' end
             when o.payment_method = 'card_on_delivery' then case when o.fulfillment_type = 'pickup' then 'card_on_pickup' else 'card_on_delivery' end
             else o.payment_method
           end as line,
           o.total, o.order_number
    from public.orders o
    where o.status <> 'cancelled'
      and (
        (o.source = 'store' and o.created_at >= v_from and o.created_at < v_to)
        or (o.source <> 'store' and o.payment_method in ('cash_on_delivery', 'card_on_delivery')
            and o.delivered_at >= v_from and o.delivered_at < v_to)
        or (o.source <> 'store' and o.payment_method in ('fawran', 'card_online')
            and o.paid_at >= v_from and o.paid_at < v_to)
      )
  )
  select coalesce(jsonb_object_agg(line, jsonb_build_object('count', n, 'total', t)), '{}'::jsonb)
    into v_lines
  from (select line, count(*) as n, sum(total) as t from money group by line) g;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', m.id, 'amount', m.amount, 'reason', m.reason, 'created_at', m.created_at,
           'by', coalesce(nullif(trim(p.full_name), ''), p.email, '')) order by m.created_at), '[]'::jsonb),
         coalesce(sum(m.amount), 0)
    into v_cash_out, v_cash_out_total
  from public.cash_movements m
  left join public.profiles p on p.id = m.created_by
  where m.day = p_day and m.kind = 'out';

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', m.id, 'amount', m.amount, 'reason', m.reason, 'created_at', m.created_at,
           'by', coalesce(nullif(trim(p.full_name), ''), p.email, '')) order by m.created_at), '[]'::jsonb),
         coalesce(sum(m.amount), 0)
    into v_cash_in, v_cash_in_total
  from public.cash_movements m
  left join public.profiles p on p.id = m.created_by
  where m.day = p_day and m.kind = 'in';

  select * into v_close from public.day_closings where day = p_day;
  select * into v_prev from public.day_closings where day < p_day order by day desc limit 1;
  v_opening := coalesce(v_close.opening_cash, v_prev.counted_cash, 0);

  v_drawer_in := coalesce((v_lines->'shop_cash'->>'total')::numeric, 0) + coalesce((v_lines->'cash_on_pickup'->>'total')::numeric, 0);
  select coalesce(sum((value->>'total')::numeric), 0) into v_total from jsonb_each(v_lines);

  return jsonb_build_object(
    'day', p_day,
    'lines', v_lines,
    'total_sales', v_total,
    'cash_out', v_cash_out,
    'cash_out_total', v_cash_out_total,
    'cash_in', v_cash_in,
    'cash_in_total', v_cash_in_total,
    'opening_cash', v_opening,
    'opening_from', case when v_close.day is null then v_prev.day end,
    'drawer_cash_in', v_drawer_in,
    'expected_cash', v_opening + v_drawer_in + v_cash_in_total - v_cash_out_total,
    'closing', case when v_close.day is null then null else jsonb_build_object(
      'opening_cash', v_close.opening_cash, 'expected_cash', v_close.expected_cash,
      'counted_cash', v_close.counted_cash, 'difference', v_close.difference,
      'total_sales', v_close.total_sales, 'note', v_close.note, 'closed_at', v_close.closed_at,
      'by', (select coalesce(nullif(trim(full_name), ''), email, '') from public.profiles where id = v_close.closed_by)) end
  );
end;
$function$;

create or replace function public.close_day(p_day date, p_opening_cash numeric, p_counted_cash numeric, p_note text default null)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  r jsonb;
  v_opening numeric;
  v_expected numeric;
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'Only QAVERA admins can close the day';
  end if;
  if p_counted_cash is null or p_counted_cash < 0 then
    raise exception 'Enter the cash counted in the drawer';
  end if;
  r := public.day_report(p_day);
  v_opening := round(coalesce(p_opening_cash, (r->>'opening_cash')::numeric), 2);
  v_expected := v_opening + (r->>'drawer_cash_in')::numeric + (r->>'cash_in_total')::numeric - (r->>'cash_out_total')::numeric;

  insert into public.day_closings (day, opening_cash, drawer_cash_in, cash_in, cash_out, expected_cash, counted_cash, difference, total_sales, report, note, closed_by, closed_at)
  values (p_day, v_opening, (r->>'drawer_cash_in')::numeric, (r->>'cash_in_total')::numeric, (r->>'cash_out_total')::numeric, v_expected,
          round(p_counted_cash, 2), round(p_counted_cash, 2) - v_expected, (r->>'total_sales')::numeric, r,
          nullif(left(trim(coalesce(p_note, '')), 300), ''), auth.uid(), now())
  on conflict (day) do update set
    opening_cash = excluded.opening_cash, drawer_cash_in = excluded.drawer_cash_in, cash_in = excluded.cash_in, cash_out = excluded.cash_out,
    expected_cash = excluded.expected_cash, counted_cash = excluded.counted_cash, difference = excluded.difference,
    total_sales = excluded.total_sales, report = excluded.report, note = excluded.note,
    closed_by = excluded.closed_by, closed_at = excluded.closed_at;

  return public.day_report(p_day);
end;
$function$;

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
  v_cash_in jsonb;
  v_cash_in_total numeric;
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
  where m.day >= v_first and m.day < v_next and m.kind = 'out';

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', m.id, 'day', m.day, 'amount', m.amount, 'reason', m.reason, 'created_at', m.created_at,
           'by', coalesce(nullif(trim(p.full_name), ''), p.email, '')) order by m.day, m.created_at), '[]'::jsonb),
         coalesce(sum(m.amount), 0)
    into v_cash_in, v_cash_in_total
  from public.cash_movements m
  left join public.profiles p on p.id = m.created_by
  where m.day >= v_first and m.day < v_next and m.kind = 'in';

  -- One line per day that had sales, cash out or a close.
  select coalesce(jsonb_agg(jsonb_build_object(
           'day', d.day,
           'total_sales', coalesce(s.total, 0),
           'orders', coalesce(s.n, 0),
           'drawer_cash_in', coalesce(s.drawer, 0),
           'cash_out', coalesce(c.amount, 0),
           'cash_in', coalesce(c.amount_in, 0),
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
  left join (select day, sum(amount) filter (where kind = 'out') as amount,
                    sum(amount) filter (where kind = 'in') as amount_in
             from public.cash_movements
             where day >= v_first and day < v_next group by day) c on c.day = d.day
  left join public.day_closings k on k.day = d.day;

  return jsonb_build_object(
    'month', v_first,
    'lines', v_lines,
    'total_sales', v_total,
    'drawer_cash_in', v_drawer,
    'cash_out', v_cash_out,
    'cash_out_total', v_cash_out_total,
    'cash_in', v_cash_in,
    'cash_in_total', v_cash_in_total,
    'days', v_days,
    'days_closed', (select count(*) from public.day_closings where day >= v_first and day < v_next),
    'difference_total', (select coalesce(sum(difference), 0) from public.day_closings where day >= v_first and day < v_next)
  );
end;
$function$;

commit;
