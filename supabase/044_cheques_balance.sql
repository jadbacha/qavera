-- QAVERA: cheques in / out, "card in / out" for the bank, and the total balance.
--   * Cheques: cheque in / cheque out by hand each day, with a note.
--   * Total balance = starting balance (10,549 QAR) + the change of every
--     day closed since. It only moves when a day is closed (or closed again).
--     Change of a closed day = counted cash − opening cash (the drawer)
--                            + bank total (card & Fawran sales + card in − card out)
--                            + cheques in − cheques out.
--     Cash on delivery is not in it: that money is with the delivery company
--     until you add it (cash in or card in) when they pay you.
--   * The starting balance counts from the first day not closed yet. Admins
--     can change the amount or the day in the till.
-- Paste into Supabase SQL Editor and click Run. Safe to run more than once.

begin;

alter table public.cash_movements drop constraint if exists cash_movements_account_check;
alter table public.cash_movements add constraint cash_movements_account_check check (account in ('drawer', 'bank', 'cheque'));

alter table public.day_closings add column if not exists balance_change numeric;

-- One row: the starting balance and the first day it counts from.
create table if not exists public.balance_settings (
  id boolean primary key default true check (id),
  start_amount numeric not null default 0,
  from_day date not null,
  updated_by uuid references auth.users(id),
  updated_at timestamptz not null default now()
);
alter table public.balance_settings enable row level security;

insert into public.balance_settings (id, start_amount, from_day)
values (true, 10549,
        coalesce((select max(day) + 1 from public.day_closings), (now() at time zone 'Asia/Qatar')::date))
on conflict (id) do nothing;

-- Days closed before this change: work out their change from the saved close.
update public.day_closings
   set balance_change = counted_cash - opening_cash + coalesce((report->>'bank_total')::numeric, 0)
 where balance_change is null;

-- Balance before a day: starting balance + every closed day from the start up to (not incl.) that day.
create or replace function public.qavera_balance_before(p_day date)
 returns numeric
 language sql
 stable
 security definer
 set search_path to 'public'
as $function$
  select coalesce(max(s.start_amount), 0)
       + coalesce((select sum(k.balance_change) from public.day_closings k, public.balance_settings b
                   where k.day >= b.from_day and k.day < p_day), 0)
  from public.balance_settings s;
$function$;

create or replace function public.qavera_total_balance()
 returns numeric
 language sql
 stable
 security definer
 set search_path to 'public'
as $function$
  select public.qavera_balance_before('9999-12-31'::date);
$function$;

-- For the till's top bar.
create or replace function public.total_balance()
 returns jsonb
 language plpgsql
 stable
 security definer
 set search_path to 'public'
as $function$
declare
  v_start record;
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'Only QAVERA admins can see the balance';
  end if;
  select * into v_start from public.balance_settings limit 1;
  return jsonb_build_object(
    'balance', public.qavera_total_balance(),
    'start_amount', coalesce(v_start.start_amount, 0),
    'from_day', v_start.from_day,
    'last_closed', (select max(k.day) from public.day_closings k where v_start.from_day is null or k.day >= v_start.from_day));
end;
$function$;

create or replace function public.set_balance_start(p_amount numeric, p_from_day date)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'Only QAVERA admins can change the balance';
  end if;
  if p_amount is null or p_from_day is null then
    raise exception 'Enter the starting balance and the day it starts from';
  end if;
  insert into public.balance_settings (id, start_amount, from_day, updated_by, updated_at)
  values (true, round(p_amount, 2), p_from_day, auth.uid(), now())
  on conflict (id) do update set start_amount = excluded.start_amount, from_day = excluded.from_day,
    updated_by = excluded.updated_by, updated_at = excluded.updated_at;
  return public.total_balance();
end;
$function$;

create or replace function public.add_cheque_movement(p_day date, p_kind text, p_amount numeric, p_reason text)
 returns uuid
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_id uuid;
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'Only QAVERA admins can add cheques';
  end if;
  if p_kind not in ('in', 'out') then
    raise exception 'Choose cheque in or cheque out';
  end if;
  if p_day is null or coalesce(p_amount, 0) <= 0 then
    raise exception 'Enter an amount';
  end if;
  if nullif(trim(p_reason), '') is null then
    raise exception 'Write a note';
  end if;
  insert into public.cash_movements (day, amount, reason, kind, account, created_by)
  values (p_day, round(p_amount, 2), left(trim(p_reason), 200), p_kind, 'cheque', auth.uid())
  returning id into v_id;
  return v_id;
end;
$function$;

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
  v_bank_moves jsonb;
  v_bank_in numeric;
  v_bank_out numeric;
  v_bank_sales numeric;
  v_cheque_moves jsonb;
  v_cheque_in numeric;
  v_cheque_out numeric;
  v_start record;
  v_before numeric;
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
  where m.day = p_day and m.kind = 'out' and m.account = 'drawer';

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', m.id, 'amount', m.amount, 'reason', m.reason, 'created_at', m.created_at,
           'by', coalesce(nullif(trim(p.full_name), ''), p.email, '')) order by m.created_at), '[]'::jsonb),
         coalesce(sum(m.amount), 0)
    into v_cash_in, v_cash_in_total
  from public.cash_movements m
  left join public.profiles p on p.id = m.created_by
  where m.day = p_day and m.kind = 'in' and m.account = 'drawer';

  -- Bank account: money added to / taken from the bank by hand.
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', m.id, 'kind', m.kind, 'amount', m.amount, 'reason', m.reason, 'created_at', m.created_at,
           'by', coalesce(nullif(trim(p.full_name), ''), p.email, '')) order by m.created_at), '[]'::jsonb),
         coalesce(sum(m.amount) filter (where m.kind = 'in'), 0),
         coalesce(sum(m.amount) filter (where m.kind = 'out'), 0)
    into v_bank_moves, v_bank_in, v_bank_out
  from public.cash_movements m
  left join public.profiles p on p.id = m.created_by
  where m.day = p_day and m.account = 'bank';

  -- Cheques in / out by hand.
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', m.id, 'kind', m.kind, 'amount', m.amount, 'reason', m.reason, 'created_at', m.created_at,
           'by', coalesce(nullif(trim(p.full_name), ''), p.email, '')) order by m.created_at), '[]'::jsonb),
         coalesce(sum(m.amount) filter (where m.kind = 'in'), 0),
         coalesce(sum(m.amount) filter (where m.kind = 'out'), 0)
    into v_cheque_moves, v_cheque_in, v_cheque_out
  from public.cash_movements m
  left join public.profiles p on p.id = m.created_by
  where m.day = p_day and m.account = 'cheque';

  -- Total balance: starting balance + the change of every closed day since.
  select * into v_start from public.balance_settings limit 1;
  v_before := public.qavera_balance_before(p_day);

  select * into v_close from public.day_closings where day = p_day;
  select * into v_prev from public.day_closings where day < p_day order by day desc limit 1;
  v_opening := coalesce(v_close.opening_cash, v_prev.counted_cash, 0);

  v_drawer_in := coalesce((v_lines->'shop_cash'->>'total')::numeric, 0) + coalesce((v_lines->'cash_on_pickup'->>'total')::numeric, 0);
  select coalesce(sum((value->>'total')::numeric), 0) into v_total from jsonb_each(v_lines);
  select coalesce(sum((value->>'total')::numeric), 0) into v_bank_sales
  from jsonb_each(v_lines) where key in ('shop_card', 'card_on_pickup', 'card_on_delivery', 'fawran', 'card_online');

  return jsonb_build_object(
    'day', p_day,
    'lines', v_lines,
    'total_sales', v_total,
    'cash_out', v_cash_out,
    'cash_out_total', v_cash_out_total,
    'cash_in', v_cash_in,
    'cash_in_total', v_cash_in_total,
    'bank_sales', v_bank_sales,
    'bank_moves', v_bank_moves,
    'bank_in_total', v_bank_in,
    'bank_out_total', v_bank_out,
    'bank_total', v_bank_sales + v_bank_in - v_bank_out,
    'cheque_moves', v_cheque_moves,
    'cheque_in_total', v_cheque_in,
    'cheque_out_total', v_cheque_out,
    'cheque_total', v_cheque_in - v_cheque_out,
    'balance', jsonb_build_object(
      'start_amount', coalesce(v_start.start_amount, 0),
      'from_day', v_start.from_day,
      'counts', v_start.from_day is null or p_day >= v_start.from_day,
      'before', v_before,
      'change', case when v_close.day is not null and (v_start.from_day is null or p_day >= v_start.from_day) then v_close.balance_change end,
      'total', public.qavera_total_balance()),
    'opening_cash', v_opening,
    'opening_from', case when v_close.day is null then v_prev.day end,
    'drawer_cash_in', v_drawer_in,
    'expected_cash', v_opening + v_drawer_in + v_cash_in_total - v_cash_out_total,
    'closing', case when v_close.day is null then null else jsonb_build_object(
      'opening_cash', v_close.opening_cash, 'expected_cash', v_close.expected_cash,
      'counted_cash', v_close.counted_cash, 'difference', v_close.difference,
      'total_sales', v_close.total_sales, 'balance_change', v_close.balance_change, 'note', v_close.note, 'closed_at', v_close.closed_at,
      'by', (select coalesce(nullif(trim(full_name), ''), email, '') from public.profiles where id = v_close.closed_by)) end
  );
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
  v_bank_moves jsonb;
  v_bank_in numeric;
  v_bank_out numeric;
  v_bank_sales numeric;
  v_cheque_moves jsonb;
  v_cheque_in numeric;
  v_cheque_out numeric;
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'Only QAVERA admins can see the month close';
  end if;

  select coalesce(jsonb_object_agg(line, jsonb_build_object('count', n, 'total', t)), '{}'::jsonb),
         coalesce(sum(t), 0)
    into v_lines, v_total
  from (select line, count(*) as n, sum(total) as t from public.qavera_money_in(v_from, v_to) group by line) g;
  select coalesce(sum(total), 0) into v_drawer from public.qavera_money_in(v_from, v_to) where line in ('shop_cash', 'cash_on_pickup');
  select coalesce(sum(total), 0) into v_bank_sales from public.qavera_money_in(v_from, v_to) where line in ('shop_card', 'card_on_pickup', 'card_on_delivery', 'fawran', 'card_online');

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', m.id, 'day', m.day, 'kind', m.kind, 'amount', m.amount, 'reason', m.reason, 'created_at', m.created_at,
           'by', coalesce(nullif(trim(p.full_name), ''), p.email, '')) order by m.day, m.created_at), '[]'::jsonb),
         coalesce(sum(m.amount) filter (where m.kind = 'in'), 0),
         coalesce(sum(m.amount) filter (where m.kind = 'out'), 0)
    into v_bank_moves, v_bank_in, v_bank_out
  from public.cash_movements m
  left join public.profiles p on p.id = m.created_by
  where m.day >= v_first and m.day < v_next and m.account = 'bank';

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', m.id, 'day', m.day, 'kind', m.kind, 'amount', m.amount, 'reason', m.reason, 'created_at', m.created_at,
           'by', coalesce(nullif(trim(p.full_name), ''), p.email, '')) order by m.day, m.created_at), '[]'::jsonb),
         coalesce(sum(m.amount) filter (where m.kind = 'in'), 0),
         coalesce(sum(m.amount) filter (where m.kind = 'out'), 0)
    into v_cheque_moves, v_cheque_in, v_cheque_out
  from public.cash_movements m
  left join public.profiles p on p.id = m.created_by
  where m.day >= v_first and m.day < v_next and m.account = 'cheque';

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', m.id, 'day', m.day, 'amount', m.amount, 'reason', m.reason, 'created_at', m.created_at,
           'by', coalesce(nullif(trim(p.full_name), ''), p.email, '')) order by m.day, m.created_at), '[]'::jsonb),
         coalesce(sum(m.amount), 0)
    into v_cash_out, v_cash_out_total
  from public.cash_movements m
  left join public.profiles p on p.id = m.created_by
  where m.day >= v_first and m.day < v_next and m.kind = 'out' and m.account = 'drawer';

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', m.id, 'day', m.day, 'amount', m.amount, 'reason', m.reason, 'created_at', m.created_at,
           'by', coalesce(nullif(trim(p.full_name), ''), p.email, '')) order by m.day, m.created_at), '[]'::jsonb),
         coalesce(sum(m.amount), 0)
    into v_cash_in, v_cash_in_total
  from public.cash_movements m
  left join public.profiles p on p.id = m.created_by
  where m.day >= v_first and m.day < v_next and m.kind = 'in' and m.account = 'drawer';

  -- One line per day that had sales, cash out or a close.
  select coalesce(jsonb_agg(jsonb_build_object(
           'day', d.day,
           'total_sales', coalesce(s.total, 0),
           'orders', coalesce(s.n, 0),
           'drawer_cash_in', coalesce(s.drawer, 0),
           'cash_out', coalesce(c.amount, 0),
           'cash_in', coalesce(c.amount_in, 0),
           'bank_sales', coalesce(s.bank, 0),
           'bank_in', coalesce(c.bank_in, 0),
           'bank_out', coalesce(c.bank_out, 0),
           'cheque_in', coalesce(c.cheque_in, 0),
           'cheque_out', coalesce(c.cheque_out, 0),
           'balance_change', case when k.day is not null and (b.from_day is null or d.day >= b.from_day) then k.balance_change end,
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
                    sum(total) filter (where line in ('shop_cash', 'cash_on_pickup')) as drawer,
                    sum(total) filter (where line in ('shop_card', 'card_on_pickup', 'card_on_delivery', 'fawran', 'card_online')) as bank
             from public.qavera_money_in(v_from, v_to) group by day) s on s.day = d.day
  left join (select day, sum(amount) filter (where kind = 'out' and account = 'drawer') as amount,
                    sum(amount) filter (where kind = 'in' and account = 'drawer') as amount_in,
                    sum(amount) filter (where kind = 'in' and account = 'bank') as bank_in,
                    sum(amount) filter (where kind = 'out' and account = 'bank') as bank_out,
                    sum(amount) filter (where kind = 'in' and account = 'cheque') as cheque_in,
                    sum(amount) filter (where kind = 'out' and account = 'cheque') as cheque_out
             from public.cash_movements
             where day >= v_first and day < v_next group by day) c on c.day = d.day
  left join public.day_closings k on k.day = d.day
  left join public.balance_settings b on true;

  return jsonb_build_object(
    'month', v_first,
    'lines', v_lines,
    'total_sales', v_total,
    'drawer_cash_in', v_drawer,
    'cash_out', v_cash_out,
    'cash_out_total', v_cash_out_total,
    'cash_in', v_cash_in,
    'cash_in_total', v_cash_in_total,
    'bank_sales', v_bank_sales,
    'bank_moves', v_bank_moves,
    'bank_in_total', v_bank_in,
    'bank_out_total', v_bank_out,
    'bank_total', v_bank_sales + v_bank_in - v_bank_out,
    'cheque_moves', v_cheque_moves,
    'cheque_in_total', v_cheque_in,
    'cheque_out_total', v_cheque_out,
    'cheque_total', v_cheque_in - v_cheque_out,
    'balance_start', public.qavera_balance_before(v_first),
    'balance_end', public.qavera_balance_before(v_next),
    'balance_total', public.qavera_total_balance(),
    'days', v_days,
    'days_closed', (select count(*) from public.day_closings where day >= v_first and day < v_next),
    'difference_total', (select coalesce(sum(difference), 0) from public.day_closings where day >= v_first and day < v_next)
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
  v_change numeric;
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
  -- What this day adds to (or takes from) the total balance.
  v_change := round(p_counted_cash, 2) - v_opening + (r->>'bank_total')::numeric + (r->>'cheque_total')::numeric;

  insert into public.day_closings (day, opening_cash, drawer_cash_in, cash_in, cash_out, expected_cash, counted_cash, difference, total_sales, balance_change, report, note, closed_by, closed_at)
  values (p_day, v_opening, (r->>'drawer_cash_in')::numeric, (r->>'cash_in_total')::numeric, (r->>'cash_out_total')::numeric, v_expected,
          round(p_counted_cash, 2), round(p_counted_cash, 2) - v_expected, (r->>'total_sales')::numeric, v_change, r,
          nullif(left(trim(coalesce(p_note, '')), 300), ''), auth.uid(), now())
  on conflict (day) do update set
    opening_cash = excluded.opening_cash, drawer_cash_in = excluded.drawer_cash_in, cash_in = excluded.cash_in, cash_out = excluded.cash_out,
    expected_cash = excluded.expected_cash, counted_cash = excluded.counted_cash, difference = excluded.difference,
    total_sales = excluded.total_sales, balance_change = excluded.balance_change, report = excluded.report, note = excluded.note,
    closed_by = excluded.closed_by, closed_at = excluded.closed_at;

  return public.day_report(p_day);
end;
$function$;

revoke execute on function public.qavera_balance_before(date) from public, anon, authenticated;
revoke execute on function public.qavera_total_balance() from public, anon, authenticated;
revoke execute on function public.total_balance() from public, anon;
revoke execute on function public.set_balance_start(numeric, date) from public, anon;
revoke execute on function public.add_cheque_movement(date, text, numeric, text) from public, anon;
grant execute on function public.total_balance() to authenticated;
grant execute on function public.set_balance_start(numeric, date) to authenticated;
grant execute on function public.add_cheque_movement(date, text, numeric, text) to authenticated;

commit;
