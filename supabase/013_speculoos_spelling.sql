-- 013: fix the spelling "Specullos" -> "Speculoos".
-- The website looks products up by name, so the database name must match
-- the pages. Old orders keep the name they were saved with.

update products
set name = 'Speculoos with Chocolate Ganache'
where name = 'Specullos with Chocolate Ganache';

select id, name, active from products where name ilike 'specul%';
