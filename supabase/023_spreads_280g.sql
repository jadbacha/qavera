-- QAVERA: spread jars are 280 g (was shown as 260 G).
-- The website matches sizes by name, so the database size must match.
-- Paste into Supabase SQL Editor and click Run. Safe to run more than once.

update public.product_variants v
set name = '280 G'
from public.products p
where p.id = v.product_id
  and lower(p.name) in ('hazelnut spread', 'pistachio spread', 'lotus spread')
  and lower(replace(v.name, ' ', '')) in ('260g', '280ml');

-- Check: three rows, all 280 G.
select p.name, v.name as size, v.price
from public.products p join public.product_variants v on v.product_id = p.id
where lower(p.name) like '% spread' and v.active;
