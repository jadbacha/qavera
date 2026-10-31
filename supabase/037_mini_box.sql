-- QAVERA: the Mini box, 2 pieces in a small white box.
--   Premium Mini QAR 10, Luxury Mini QAR 15.
--   Customers can pick the 2 flavours, like the other sizes.
-- Paste into Supabase SQL Editor and click Run. Safe to run more than once.

begin;

with mini(product, price) as (
  values ('premium', 10::numeric), ('luxury', 15::numeric)
),
updated as (
  update public.product_variants v
     set price = m.price, pieces = 2, active = true
    from mini m, public.products p
   where p.id = v.product_id and lower(p.name) = m.product and lower(v.name) = 'mini'
  returning v.product_id
)
insert into public.product_variants (product_id, name, price, pieces, active)
select p.id, 'Mini', m.price, 2, true
from mini m
join public.products p on lower(p.name) = m.product
where not exists (select 1 from updated u where u.product_id = p.id)
  and not exists (select 1 from public.product_variants v where v.product_id = p.id and lower(v.name) = 'mini');

commit;

-- Check: should list Premium Mini 10 and Luxury Mini 15.
select p.name as box, v.name as size, v.pieces, v.price, v.active
from public.product_variants v
join public.products p on p.id = v.product_id
where lower(v.name) = 'mini'
order by p.name;
