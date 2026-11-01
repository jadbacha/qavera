-- QAVERA: daily close (till "Day close" tab, admins only).
--   * Sales of the day by payment method, counted on the day the money comes in:
--       shop sales when sold; cash / card on delivery or pickup when the order
--       is delivered or collected; Fawran when marked received; card online
--       when paid.
--   * Cash out: money taken from the drawer to pay for something.
--   * Close day: opening cash (carried from the last close) + cash into the
--     drawer (shop cash + cash on pickup) − cash out = expected cash; the
--     counted cash and the difference are saved.
--     Cash on delivery stays with the delivery company: shown, not in the drawer.
-- Paste into Supabase SQL Editor and click Run. Safe to run more than once.

begin;

-- When an order was delivered / collected, and when it was paid.
alter table public.orders
  add column if not exists delivered_at timestamptz,
  add column if not exists paid_at timestamptz;

create or replace function public.orders_set_money_times()
 returns trigger
 language plpgsql
as $function$
begin
  if new.status = 'delivered' and new.delivered_at is null
     and (tg_op = 'INSERT' or old.status is distinct from 'delivered') then
    new.delivered_at := now();
  end if;
  if new.status <> 'delivered' and tg_op = 'UPDATE' and old.status = 'delivered' then
    new.delivered_at := null;  -- moved back (e.g. by mistake)
  end if;
  if new.payment_status = 'paid' and new.paid_at is null
     and (tg_op = 'INSERT' or old.payment_status is distinct from 'paid') then
    new.paid_at := coalesce(new.online_paid_at, now());
  end if;
  if new.payment_status <> 'paid' and tg_op = 'UPDATE' and old.payment_status = 'paid' then
    new.paid_at := null;
  end if;
  return new;
end;
$function$;

drop trigger if exists orders_money_times on public.orders;
create trigger orders_money_times
  before insert or update of status, payment_status on public.orders
  for each row execute function public.orders_set_money_times();

-- Older orders: best guess from the chosen date (noon, Qatar time), else when placed.
update public.orders
   set delivered_at = coalesce((scheduled_date + time '12:00') at time zone 'Asia/Qatar', created_at)
 where status = 'delivered' and delivered_at is null;
update public.orders
   set paid_at = coalesce(online_paid_at, (scheduled_date + time '12:00') at time zone 'Asia/Qatar', created_at)
 where payment_status = 'paid' and paid_at is null;

-- Cash taken out of the drawer.
create table if not exists public.cash_movements (
  id uuid primary key default gen_random_uuid(),
  day date not null,
  amount numeric not null check (amount > 0),
  reason text not null,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now()
);
alter table public.cash_movements enable row level security;

-- One saved close per day.
create table if not exists public.day_closings (
  day date primary key,
  opening_cash numeric not null default 0,
  drawer_cash_in numeric not null default 0,
  cash_out numeric not null default 0,
  expected_cash numeric not null default 0,
  counted_cash numeric not null default 0,
  difference numeric not null default 0,
  total_sales numeric not null default 0,
  report jsonb,
  note text,
  closed_by uuid references auth.users(id),
  closed_at timestamptz not null default now()
);
alter table public.day_closings enable row level security;

-- The report for one day (Qatar time).
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
  where m.day = p_day;

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
    'opening_cash', v_opening,
    'opening_from', case when v_close.day is null then v_prev.day end,
    'drawer_cash_in', v_drawer_in,
    'expected_cash', v_opening + v_drawer_in - v_cash_out_total,
    'closing', case when v_close.day is null then null else jsonb_build_object(
      'opening_cash', v_close.opening_cash, 'expected_cash', v_close.expected_cash,
      'counted_cash', v_close.counted_cash, 'difference', v_close.difference,
      'total_sales', v_close.total_sales, 'note', v_close.note, 'closed_at', v_close.closed_at,
      'by', (select coalesce(nullif(trim(full_name), ''), email, '') from public.profiles where id = v_close.closed_by)) end
  );
end;
$function$;

create or replace function public.add_cash_out(p_day date, p_amount numeric, p_reason text)
 returns uuid
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_id uuid;
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'Only QAVERA admins can take cash out';
  end if;
  if p_day is null or coalesce(p_amount, 0) <= 0 then
    raise exception 'Enter an amount';
  end if;
  if nullif(trim(p_reason), '') is null then
    raise exception 'Write what the cash was for';
  end if;
  insert into public.cash_movements (day, amount, reason, created_by)
  values (p_day, round(p_amount, 2), left(trim(p_reason), 200), auth.uid())
  returning id into v_id;
  return v_id;
end;
$function$;

create or replace function public.delete_cash_out(p_id uuid)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'Only QAVERA admins can remove cash out';
  end if;
  delete from public.cash_movements where id = p_id;
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
  v_expected := v_opening + (r->>'drawer_cash_in')::numeric - (r->>'cash_out_total')::numeric;

  insert into public.day_closings (day, opening_cash, drawer_cash_in, cash_out, expected_cash, counted_cash, difference, total_sales, report, note, closed_by, closed_at)
  values (p_day, v_opening, (r->>'drawer_cash_in')::numeric, (r->>'cash_out_total')::numeric, v_expected,
          round(p_counted_cash, 2), round(p_counted_cash, 2) - v_expected, (r->>'total_sales')::numeric, r,
          nullif(left(trim(coalesce(p_note, '')), 300), ''), auth.uid(), now())
  on conflict (day) do update set
    opening_cash = excluded.opening_cash, drawer_cash_in = excluded.drawer_cash_in, cash_out = excluded.cash_out,
    expected_cash = excluded.expected_cash, counted_cash = excluded.counted_cash, difference = excluded.difference,
    total_sales = excluded.total_sales, report = excluded.report, note = excluded.note,
    closed_by = excluded.closed_by, closed_at = excluded.closed_at;

  return public.day_report(p_day);
end;
$function$;

revoke execute on function public.day_report(date) from public, anon;
revoke execute on function public.add_cash_out(date, numeric, text) from public, anon;
revoke execute on function public.delete_cash_out(uuid) from public, anon;
revoke execute on function public.close_day(date, numeric, numeric, text) from public, anon;
grant execute on function public.day_report(date) to authenticated;
grant execute on function public.add_cash_out(date, numeric, text) to authenticated;
grant execute on function public.delete_cash_out(uuid) to authenticated;
grant execute on function public.close_day(date, numeric, numeric, text) to authenticated;

commit;
