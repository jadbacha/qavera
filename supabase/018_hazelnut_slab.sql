-- QAVERA: the milk chocolate slab is now hazelnut only (no cashew).
-- The website finds products by name, so the database name must match.
-- Paste into Supabase SQL Editor and click Run. Safe to run more than once.

update public.products
set name = 'Milk Chocolate with Hazelnuts'
where lower(name) in ('milk chocolate with hazelnuts and cashew',
                      'dark chocolate with hazelnuts and cashew');

-- Check: one row, Milk Chocolate with Hazelnuts.
select name, active from public.products where lower(name) like '%hazelnuts%';
