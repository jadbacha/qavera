-- QAVERA: Mix Assorted is back on sale (500 G, QAR 190).
-- Only needed if you already ran 014_menu_october.sql before this change.
-- Paste into Supabase SQL Editor and click Run. Safe to run more than once.

update public.products
set active = true
where lower(name) = 'mix assorted';

update public.product_variants v
set active = true, price = 190
from public.products p
where p.id = v.product_id
  and lower(p.name) = 'mix assorted'
  and lower(replace(v.name, ' ', '')) = '500g';

-- Check: one row, Mix Assorted, 500 G, 190, active.
select p.name, p.active, v.name as size, v.price, v.active as size_active
from public.products p
join public.product_variants v on v.product_id = p.id
where lower(p.name) = 'mix assorted';
