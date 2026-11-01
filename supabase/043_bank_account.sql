-- QAVERA: bank account in the day and month close (admins only).
--   Money that goes to the bank: shop card, card on pickup, card on delivery,
--   Fawran and card online. Plus bank in / bank out by hand, with a note.
--   Bank total = those sales + bank in − bank out. The cash drawer is unchanged.
-- Paste into Supabase SQL Editor and click Run. Safe to run more than once.

begin;

alter table public.cash_movements
  add column if not exists account text not null default 'drawer';
alter table public.cash_movements drop constraint if exists cash_movements_account_check;
alter table public.cash_movements add constraint cash_movements_account_check check (account in ('drawer', 'bank'));

create or replace function public.add_bank_movement(p_day date, p_kind text, p_amount numeric, p_reason text)
 returns uuid
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_id uuid;
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'Only QAVERA admins can change the bank account';
  end if;
  if p_kind not in ('in', 'out') then
    raise exception 'Choose bank in or bank out';
  end if;
  if p_day is null or coalesce(p_amount, 0) <= 0 then
    raise exception 'Enter an amount';
  end if;
  if nullif(trim(p_reason), '') is null then
    raise exception 'Write a note';
  end if;
  insert into public.cash_movements (day, amount, reason, kind, account, created_by)
  values (p_day, round(p_amount, 2), left(trim(p_reason), 200), p_kind, 'bank', auth.uid())
  returning id into v_id;
  return v_id;
end;
$function$;

revoke execute on function public.add_bank_movement(date, text, numeric, text) from public, anon;
grant execute on function public.add_bank_movement(date, text, numeric, text) to authenticated;

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
                    sum(amount) filter (where kind = 'out' and account = 'bank') as bank_out
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
    'bank_sales', v_bank_sales,
    'bank_moves', v_bank_moves,
    'bank_in_total', v_bank_in,
    'bank_out_total', v_bank_out,
    'bank_total', v_bank_sales + v_bank_in - v_bank_out,
    'days', v_days,
    'days_closed', (select count(*) from public.day_closings where day >= v_first and day < v_next),
    'difference_total', (select coalesce(sum(difference), 0) from public.day_closings where day >= v_first and day < v_next)
  );
end;
$function$;

commit;
