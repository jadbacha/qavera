-- QAVERA: new product "Custom Design Chocolate", 10 QAR a piece.
--   * Shows in the admin page (New order, Stock) and in the till.
--   * Not sold on the website: the shop page shows it with a WhatsApp button.
-- Paste into Supabase SQL Editor and click Run. Safe to run more than once.

begin;

do $add$
begin
  if not exists (select 1 from public.products where lower(name) = 'custom design chocolate') then
    if exists (select 1 from information_schema.columns
               where table_schema = 'public' and table_name = 'products' and column_name = 'slug') then
      execute $sql$insert into public.products (name, slug, category, active)
               values ('Custom Design Chocolate', 'custom-design-chocolate', 'custom', true)$sql$;
    else
      insert into public.products (name, category, active) values ('Custom Design Chocolate', 'custom', true);
    end if;
  end if;
end
$add$;

insert into public.product_variants (product_id, name, price, active)
select p.id, 'Per piece', 10, true
from public.products p
where lower(p.name) = 'custom design chocolate'
  and not exists (select 1 from public.product_variants v where v.product_id = p.id and lower(v.name) = 'per piece');

commit;

-- Check: should show one line, 10.
select p.name, p.category, v.name as variant, v.price
from public.products p join public.product_variants v on v.product_id = p.id
where lower(p.name) = 'custom design chocolate';
