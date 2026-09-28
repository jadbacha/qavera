-- QAVERA: security fixes + points on delivery
-- Paste into Supabase SQL Editor and click Run. Safe to run more than once.

begin;

-- 1. Customers may only edit their name, phone and email (not points or role).
revoke update on public.profiles from anon, authenticated;
grant update (full_name, phone, email) on public.profiles to authenticated;

-- 2. Orders can only be created through create_qavera_order (which checks prices),
--    not by inserting rows directly.
drop policy if exists "Users can create their own orders" on public.orders;
drop policy if exists "Users can create their own order items" on public.order_items;

-- 3. Points: award when an order becomes 'delivered' (100 points per QAR 1,000
--    spent on products, after any points discount, excluding delivery).
--    If a delivered order is later cancelled, the awarded points are taken back.
--    If any order is cancelled, the points the customer spent on it are returned.
alter table public.orders
  add column if not exists points_earned integer not null default 0,
  add column if not exists points_awarded_at timestamptz,
  add column if not exists points_refunded_at timestamptz;

create or replace function public.handle_order_points()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if new.user_id is null or new.status is not distinct from old.status then
    return new;
  end if;

  -- Award points once, when the order is delivered.
  if new.status = 'delivered' and new.points_awarded_at is null then
    new.points_earned := floor(greatest(new.subtotal - new.points_discount, 0) * 0.1);
    new.points_awarded_at := now();
    update public.profiles
      set points = points + new.points_earned
      where id = new.user_id;
  end if;

  if new.status = 'cancelled' then
    -- Take back points earned from this order, if any were awarded.
    if new.points_awarded_at is not null and new.points_earned > 0 then
      update public.profiles
        set points = greatest(points - new.points_earned, 0)
        where id = new.user_id;
      new.points_earned := 0;
      new.points_awarded_at := null;
    end if;

    -- Return points the customer spent on this order (once).
    if new.points_used > 0 and new.points_refunded_at is null then
      update public.profiles
        set points = points + new.points_used
        where id = new.user_id;
      new.points_refunded_at := now();
    end if;
  end if;

  return new;
end;
$$;

revoke execute on function public.handle_order_points() from public, anon, authenticated;

drop trigger if exists on_order_status_change on public.orders;
create trigger on_order_status_change
  before update of status on public.orders
  for each row execute function public.handle_order_points();

commit;
