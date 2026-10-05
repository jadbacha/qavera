-- QAVERA: launch day. Clears the TEST website orders so the site starts fresh.
--   * Deletes website orders only. Shop sales from the till are real and are KEPT.
--   * Sets everyone's points back to 0 (points so far came from test orders).
--   * Products, prices, stock, accounts and saved addresses are not touched.
-- Run ONCE, on launch day, just before going live. This cannot be undone.

-- 1. Preview: how many of each will be affected.
select
  (select count(*) from public.orders where coalesce(source, 'website') <> 'store') as website_orders_to_delete,
  (select count(*) from public.orders where source = 'store')                      as shop_sales_kept,
  (select count(*) from public.profiles where points <> 0)                         as accounts_with_points;

-- 2. Clean up.
begin;

delete from public.order_items
where order_id in (select id from public.orders where coalesce(source, 'website') <> 'store');

delete from public.orders
where coalesce(source, 'website') <> 'store';

update public.profiles set points = 0 where points <> 0;

commit;

-- 3. Check: website orders 0, shop sales unchanged, points 0.
select
  (select count(*) from public.orders where coalesce(source, 'website') <> 'store') as website_orders_left,
  (select count(*) from public.orders where source = 'store')                      as shop_sales_kept,
  (select count(*) from public.profiles where points <> 0)                         as accounts_with_points;
