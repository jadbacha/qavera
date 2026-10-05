-- QAVERA: "Chocolate Gianduja" is now called "Hazelnut Praline".
-- The website finds products by name, so the database name must match.
-- Paste into Supabase SQL Editor and click Run. Safe to run more than once.

update public.products
set name = 'Hazelnut Praline'
where lower(name) in ('chocolate gianduja', 'chocolate gianduja crispy rice');

-- Check: one row, Hazelnut Praline.
select name, active from public.products where lower(name) like '%praline%';
