-- QAVERA: allow the new one-hour order times ("13:00") in the orders table.
-- Fixes: new row for relation "orders" violates check constraint "orders_time_slot_check".
-- Older orders keep their time windows (e.g. "12:00-16:00").
-- Paste into Supabase SQL Editor and click Run. Safe to run more than once.

alter table public.orders drop constraint if exists orders_time_slot_check;
alter table public.orders add constraint orders_time_slot_check
  check (time_slot is null
         or time_slot in ('12:00-16:00', '18:00-23:00', '10:00-14:00', '16:00-21:00', '13:00-18:00')
         or time_slot ~ '^([01][0-9]|2[0-3]):00$');

-- Check: should show the new rule.
select pg_get_constraintdef(oid) as rule from pg_constraint where conname = 'orders_time_slot_check';
