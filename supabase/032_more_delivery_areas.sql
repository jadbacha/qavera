-- QAVERA: popular area names customers type, with their delivery charge.
-- Paste into Supabase SQL Editor and click Run. Safe to run more than once.

insert into public.delivery_areas (name, fee)
select v.name, v.fee
from (values
  ('West Bay', 30),
  ('The Pearl', 50),
  ('Katara', 50),
  ('Al Rayyan', 30)
) as v(name, fee)
where not exists (select 1 from public.delivery_areas a where lower(a.name) = lower(v.name));

-- Check: should list the four areas.
select name, fee from public.delivery_areas
where name in ('West Bay', 'The Pearl', 'Katara', 'Al Rayyan') order by name;
