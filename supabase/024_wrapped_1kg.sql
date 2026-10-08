-- QAVERA: wrapped chocolate is sold from 1 kg (QAR 380), and two products are renamed:
--   Crispy Feuilletine -> Crispy Pistachio,  Hazelnut Praline -> Crispy Hazelnut.
-- The website finds products by name and size, so the database must match.
-- Paste into Supabase SQL Editor and click Run. Safe to run more than once.

update public.products set name = 'Crispy Pistachio' where lower(name) = 'crispy feuilletine';
update public.products set name = 'Crispy Hazelnut'  where lower(name) in ('hazelnut praline', 'chocolate gianduja');

update public.product_variants v
set name = '1 KG', price = 380
from public.products p
where p.id = v.product_id
  and p.category = 'assorted'
  and lower(replace(v.name, ' ', '')) in ('500g', '1kg');

-- Check: five rows, all 1 KG at 380.
select p.name, v.name as size, v.price, p.active
from public.products p join public.product_variants v on v.product_id = p.id
where p.category = 'assorted' and p.active and v.active
order by p.name;
