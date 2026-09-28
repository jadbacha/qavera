-- QAVERA: admin orders page (admin.html) + order status changes.
-- Paste into Supabase SQL Editor and click Run. Safe to run more than once.
-- At the bottom, change the email to the one you log in to the website with.

begin;

-- Only these statuses are allowed from now on.
alter table public.orders drop constraint if exists orders_status_check;
alter table public.orders add constraint orders_status_check
  check (status in ('pending', 'confirmed', 'preparing', 'out_for_delivery', 'delivered', 'cancelled'))
  not valid;

-- True when the logged-in user's profile has role = 'admin'.
-- Customers cannot change their own role (see 001_security_and_points.sql).
create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid() and role = 'admin'
  );
$$;

revoke execute on function public.is_admin() from public, anon;
grant execute on function public.is_admin() to authenticated;

-- Admins can see every order and its items.
drop policy if exists "Admins can view all orders" on public.orders;
create policy "Admins can view all orders"
  on public.orders for select
  to authenticated
  using (public.is_admin());

drop policy if exists "Admins can view all order items" on public.order_items;
create policy "Admins can view all order items"
  on public.order_items for select
  to authenticated
  using (public.is_admin());

-- The only way to change an order's status. Points are handled by the
-- on_order_status_change trigger (001): 'delivered' awards, 'cancelled' refunds.
create or replace function public.admin_set_order_status(p_order_id uuid, p_status text)
returns table(order_id uuid, status text, points_earned integer)
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_current text;
begin
  if not public.is_admin() then
    raise exception 'Only QAVERA admins can change orders';
  end if;

  if p_status not in ('pending', 'confirmed', 'preparing', 'out_for_delivery', 'delivered', 'cancelled') then
    raise exception 'Invalid order status';
  end if;

  select o.status into v_current from public.orders o where o.id = p_order_id for update;

  if not found then
    raise exception 'Order not found';
  end if;

  if v_current = 'cancelled' then
    raise exception 'This order is cancelled and cannot be changed';
  end if;

  if v_current = 'delivered' and p_status <> 'cancelled' then
    raise exception 'This order is already delivered';
  end if;

  update public.orders o set status = p_status where o.id = p_order_id;

  return query
    select o.id, o.status, o.points_earned from public.orders o where o.id = p_order_id;
end;
$$;

revoke execute on function public.admin_set_order_status(uuid, text) from public, anon;
grant execute on function public.admin_set_order_status(uuid, text) to authenticated;

-- Make your account an admin (use the email you log in to the website with).
update public.profiles set role = 'admin' where lower(email) = lower('jadbacha2004.jb@gmail.com');

commit;
