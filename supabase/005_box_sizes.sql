-- QAVERA: record how many pieces each Premium / Luxury box holds, so customized
-- boxes (flavour picks) can be checked at checkout. Safe to run more than once.

update public.product_variants v
set pieces = case
    when lower(trim(v.name)) in ('s', 'small') or lower(trim(v.name)) like 'small %' or lower(trim(v.name)) like 's %' then 12
    when lower(trim(v.name)) in ('m', 'medium') or lower(trim(v.name)) like 'medium %' or lower(trim(v.name)) like 'm %' then 25
    when lower(trim(v.name)) in ('l', 'large') or lower(trim(v.name)) like 'large %' or lower(trim(v.name)) like 'l %' then 48
  end
from public.products p
where p.id = v.product_id
  and lower(trim(p.name)) in ('premium', 'luxury');

-- Check: every Premium / Luxury size should show 12, 25 or 48.
select p.name as product, v.name as size, v.price, v.pieces
from public.product_variants v
join public.products p on p.id = v.product_id
where lower(trim(p.name)) in ('premium', 'luxury')
order by p.name, v.pieces nulls last;
