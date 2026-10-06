-- QAVERA: opening. Website orders can't be scheduled before Saturday 10 October 2026.
-- Shop sales from the till are not affected. After 10 October this check has
-- no effect any more, so it never needs to be removed.
-- Paste into Supabase SQL Editor and click Run. Safe to run more than once.

create or replace function public.check_first_delivery_date()
returns trigger
language plpgsql
set search_path to 'public'
as $$
begin
  if coalesce(new.source, 'website') <> 'store'
     and new.scheduled_date is not null
     and new.scheduled_date < date '2026-10-10' then
    raise exception 'Our first deliveries and pickups are on Saturday 10 October. Please choose 10 October or later.';
  end if;
  return new;
end;
$$;

drop trigger if exists orders_first_delivery_date on public.orders;
create trigger orders_first_delivery_date
  before insert on public.orders
  for each row execute function public.check_first_delivery_date();

-- Check: one row, the trigger is in place.
select tgname from pg_trigger where tgname = 'orders_first_delivery_date';
