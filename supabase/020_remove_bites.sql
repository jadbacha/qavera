-- QAVERA: Bites are no longer sold (website and shop till).
-- Hidden, not deleted, so past orders keep their details.
-- Paste into Supabase SQL Editor and click Run. Safe to run more than once.

update public.products
set active = false
where category = 'bites'
   or lower(name) in ('pretzels with chocolate', 'pringles with chocolate', 'almond florentine with chocolate');

-- Check: these should all show active = false.
select name, active from public.products
where category = 'bites' or lower(name) like '%with chocolate';
