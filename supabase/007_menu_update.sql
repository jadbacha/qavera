-- QAVERA: match the new menu.
--   Spreads: 280ml / QAR 60  ->  260 G / QAR 50
--   Bites:   50 G  / QAR 25  ->  100 G / QAR 25
--   Almond Florentine with Chocolate is no longer sold (hidden, not deleted,
--   so past orders keep their details).
-- Paste into Supabase SQL Editor and click Run. Safe to run more than once.

begin;

update public.product_variants v
set name = '260 G', price = 50
from public.products p
where p.id = v.product_id
  and lower(p.name) in ('hazelnut spread', 'pistachio spread', 'lotus spread')
  and lower(replace(v.name, ' ', '')) = '280ml';

update public.product_variants v
set name = '100 G'
from public.products p
where p.id = v.product_id
  and lower(p.name) in ('pretzels with chocolate', 'pringles with chocolate', 'almond florentine with chocolate')
  and lower(replace(v.name, ' ', '')) = '50g';

update public.products
set active = false
where lower(name) = 'almond florentine with chocolate';

commit;

-- Check: spreads show 260 G / 50, bites 100 G / 25, Florentine inactive.
select p.category, p.name, p.active, v.name as size, v.price
from public.products p
join public.product_variants v on v.product_id = p.id
where lower(p.name) like '% spread' or lower(p.name) like '% with chocolate'
order by p.name;
