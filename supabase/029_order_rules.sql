-- QAVERA: two old rules on the orders table (created when the database was
-- first set up, not in these files) blocked the QAR 25 delivery charge and
-- discounted orders. Already run in Supabase on 11 October 2026; kept here
-- as a record. Safe to run more than once.

alter table public.orders drop constraint if exists valid_delivery_fee;
alter table public.orders add constraint valid_delivery_fee check (delivery_fee >= 0);

-- The total must add up, counting shop / WhatsApp discounts too.
alter table public.orders drop constraint if exists valid_order_total;
alter table public.orders add constraint valid_order_total
  check (total >= 0 and total = subtotal + delivery_fee - points_discount - discount_amount) not valid;
