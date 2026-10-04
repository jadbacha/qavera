-- QAVERA: match the October menu.
--   Premium Box:  12 / 25 / 48 pieces  ->  QAR 75 / 150 / 290
--   Luxury Box:   12 / 25 / 48 pieces  ->  QAR 100 / 210 / 390
--   Slabs:        QAR 50 -> QAR 60. "Dark Chocolate with Hazelnuts and Cashew"
--                 is now milk chocolate; "Milk Chocolate with Mix Nuts" is hidden.
--   Bites:        QAR 25 -> QAR 20
--   Wrapped:      Mandiant -> Mendiant, "Chocolate Gianduja Crispy Rice" ->
--                 "Chocolate Gianduja"; Speculoos is hidden.
-- Hidden products are not deleted, so past orders keep their details.
-- Paste into Supabase SQL Editor and click Run. Safe to run more than once.

begin;

-- Box prices, matched by size (S / Small, M / Medium, L / Large).
update public.product_variants v
set price = case
    when lower(p.name) = 'premium' and lower(v.name) ~ '^(s|small)\y' then 75
    when lower(p.name) = 'premium' and lower(v.name) ~ '^(m|medium)\y' then 150
    when lower(p.name) = 'premium' and lower(v.name) ~ '^(l|large)\y' then 290
    when lower(p.name) = 'luxury'  and lower(v.name) ~ '^(s|small)\y' then 100
    when lower(p.name) = 'luxury'  and lower(v.name) ~ '^(m|medium)\y' then 210
    when lower(p.name) = 'luxury'  and lower(v.name) ~ '^(l|large)\y' then 390
    else v.price
  end
from public.products p
where p.id = v.product_id
  and lower(p.name) in ('premium', 'luxury');

-- Slabs
update public.products
set name = 'Milk Chocolate with Hazelnuts and Cashew'
where lower(name) = 'dark chocolate with hazelnuts and cashew';

update public.products
set active = false
where lower(name) = 'milk chocolate with mix nuts';

update public.product_variants v
set price = 60
from public.products p
where p.id = v.product_id
  and lower(p.name) in ('white chocolate with almond and raspberry',
                        'milk chocolate with hazelnuts and cashew');

-- Bites
update public.product_variants v
set price = 20
from public.products p
where p.id = v.product_id
  and lower(p.name) in ('pretzels with chocolate', 'pringles with chocolate');

-- Wrapped chocolate
update public.products set name = 'Hazelnut Mendiant' where lower(name) = 'hazelnut mandiant';
update public.products set name = 'Almond Mendiant'   where lower(name) = 'almond mandiant';
update public.products set name = 'Chocolate Gianduja' where lower(name) = 'chocolate gianduja crispy rice';

update public.products
set active = false
where lower(name) in ('speculoos with chocolate ganache',
                      'specullos with chocolate ganache');

commit;

-- Check: active products with their sizes and prices.
select p.name, v.name as size, v.price
from public.products p
join public.product_variants v on v.product_id = p.id and v.active
where p.active
order by p.category nulls first, p.name, v.price;
