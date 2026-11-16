-- QAVERA: the Mini box of Chocolate Bonbons (2 pieces) is QAR 20.
-- The website, the admin page and the till read the price from here.
-- Paste into Supabase SQL Editor and click Run. Safe to run more than once.

update public.product_variants v
   set price = 20
  from public.products p
 where p.id = v.product_id
   and lower(p.name) = 'chocolate bonbons'
   and lower(v.name) = 'mini';

-- Check: Mini should show 20.
select p.name, v.name as size, v.pieces, v.price
from public.products p join public.product_variants v on v.product_id = p.id
where lower(p.name) = 'chocolate bonbons' and v.active
order by v.price;
