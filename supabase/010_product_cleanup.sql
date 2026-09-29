-- QAVERA: switch off the old catalogue products from the first setup.
-- They were replaced by the separate products the website and the till use,
-- and were never ordered. They are hidden (active = false), not deleted.
-- Paste into Supabase SQL Editor and click Run. Safe to run more than once.

begin;

update public.products
set active = false
where id in (
  'e982561c-1214-4bbd-866a-cf046aa59e3b', -- Assorted Fine Chocolate Wrapped (6 flavours as sizes)
  '22faf722-0b39-4d02-a651-38d717f897b7', -- Bites (50g)
  'cec02254-b8ab-4ab7-a79d-8c2a22631c0d', -- Slabs (100g)
  '614e92a3-74d9-40ee-96fa-0282f2a78a1f'  -- Spreads (280ml, QAR 60)
);

commit;

-- Check: everything the website and till now show.
select p.category, p.name as product, v.name as size, v.price
from public.products p
join public.product_variants v on v.product_id = p.id and v.active
where p.active
order by p.category, p.name, v.price;
