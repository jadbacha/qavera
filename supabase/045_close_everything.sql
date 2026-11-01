-- QAVERA: closing a day closes everything, and every closed day counts in
-- the total balance.
--   * Change of a closed day = cash sales + cash in − cash out
--                            + card & Fawran sales + card in − card out
--                            + cheques in − cheques out.
--   * Every closed day counts (any date), on top of the starting balance.
--   * Counting the cash is optional: left empty, the counted cash is the
--     expected cash.
--   * Days already closed are worked out again with this rule.
-- Paste into Supabase SQL Editor and click Run. Safe to run more than once.

begin;

-- Balance before a day: starting balance + every closed day before it.
create or replace function public.qavera_balance_before(p_day date)
 returns numeric
 language sql
 stable
 security definer
 set search_path to 'public'
as $function$
  select coalesce((select max(start_amount) from public.balance_settings), 0)
       + coalesce((select sum(k.balance_change) from public.day_closings k where k.day < p_day), 0);
$function$;

-- Every day counts now, whatever its date.
do $patch$
declare
  v_def text;
  v_new text;
begin
  v_def := pg_get_functiondef('public.day_report(date)'::regprocedure);
  v_new := replace(v_def, $a$'counts', v_start.from_day is null or p_day >= v_start.from_day,$a$, $a$'counts', true,$a$);
  v_new := replace(v_new, $a$'change', case when v_close.day is not null and (v_start.from_day is null or p_day >= v_start.from_day) then v_close.balance_change end,$a$, $a$'change', v_close.balance_change,$a$);
  if v_new <> v_def then execute v_new; end if;

  v_def := pg_get_functiondef('public.month_report(date)'::regprocedure);
  v_new := replace(v_def, $a$'balance_change', case when k.day is not null and (b.from_day is null or d.day >= b.from_day) then k.balance_change end,$a$, $a$'balance_change', k.balance_change,$a$);
  if v_new <> v_def then execute v_new; end if;
end
$patch$;

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
  v_counted numeric;
  v_change numeric;
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'Only QAVERA admins can close the day';
  end if;
  if p_counted_cash < 0 then
    raise exception 'The counted cash can''t be below 0';
  end if;
  r := public.day_report(p_day);
  v_opening := round(coalesce(p_opening_cash, (r->>'opening_cash')::numeric), 2);
  v_expected := v_opening + (r->>'drawer_cash_in')::numeric + (r->>'cash_in_total')::numeric - (r->>'cash_out_total')::numeric;
  v_counted := round(coalesce(p_counted_cash, v_expected), 2);
  -- Everything that came in today minus everything that went out.
  v_change := (r->>'drawer_cash_in')::numeric + (r->>'cash_in_total')::numeric - (r->>'cash_out_total')::numeric
            + (r->>'bank_total')::numeric + (r->>'cheque_total')::numeric;

  insert into public.day_closings (day, opening_cash, drawer_cash_in, cash_in, cash_out, expected_cash, counted_cash, difference, total_sales, balance_change, report, note, closed_by, closed_at)
  values (p_day, v_opening, (r->>'drawer_cash_in')::numeric, (r->>'cash_in_total')::numeric, (r->>'cash_out_total')::numeric, v_expected,
          v_counted, v_counted - v_expected, (r->>'total_sales')::numeric, v_change, r,
          nullif(left(trim(coalesce(p_note, '')), 300), ''), auth.uid(), now())
  on conflict (day) do update set
    opening_cash = excluded.opening_cash, drawer_cash_in = excluded.drawer_cash_in, cash_in = excluded.cash_in, cash_out = excluded.cash_out,
    expected_cash = excluded.expected_cash, counted_cash = excluded.counted_cash, difference = excluded.difference,
    total_sales = excluded.total_sales, balance_change = excluded.balance_change, report = excluded.report, note = excluded.note,
    closed_by = excluded.closed_by, closed_at = excluded.closed_at;

  return public.day_report(p_day);
end;
$function$;

-- Days already closed: work them out again with the new rule.
update public.day_closings
   set balance_change = drawer_cash_in + cash_in - cash_out
                      + coalesce((report->>'bank_total')::numeric, 0)
                      + coalesce((report->>'cheque_total')::numeric, 0);

commit;
