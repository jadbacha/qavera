-- QAVERA: three new categories, all 100 G at QAR 60.
--   * Mendiant: chocolate chips with dried fruit / with nuts.
--   * Bites: chopped almonds with milk / dark chocolate, pistachio dipped in
--     white chocolate, pecan with milk chocolate, hazelnut dipped in milk chocolate.
--   * Pâtes de fruits: pineapple, guava.
-- They show on the website, the admin page and the till.
-- Paste into Supabase SQL Editor and click Run. Safe to run more than once.

begin;

-- Adds a product (if missing) and its size (if missing), or updates the price.
create or replace function pg_temp.qv_add(p_name text, p_category text, p_variant text, p_price numeric, p_pieces integer default null)
 returns void
 language plpgsql
as $function$
declare
  v_id uuid;
begin
  select id into v_id from public.products where lower(name) = lower(p_name) limit 1;
  if v_id is null then
    if exists (select 1 from information_schema.columns
               where table_schema = 'public' and table_name = 'products' and column_name = 'slug') then
      execute 'insert into public.products (name, slug, category, active) values ($1, $2, $3, true) returning id'
        into v_id using p_name, lower(regexp_replace(p_name, '[^A-Za-z0-9]+', '-', 'g')), p_category;
    else
      insert into public.products (name, category, active) values (p_name, p_category, true) returning id into v_id;
    end if;
  else
    update public.products set active = true where id = v_id;
  end if;

  if exists (select 1 from public.product_variants where product_id = v_id and lower(name) = lower(p_variant)) then
    update public.product_variants set price = p_price, pieces = coalesce(p_pieces, pieces), active = true
     where product_id = v_id and lower(name) = lower(p_variant);
  else
    insert into public.product_variants (product_id, name, price, pieces, active)
    values (v_id, p_variant, p_price, p_pieces, true);
  end if;
end;
$function$;

select pg_temp.qv_add('Chocolate Chips with Dried Fruit', 'mendiant', '100 G', 60);
select pg_temp.qv_add('Chocolate Chips with Nuts', 'mendiant', '100 G', 60);
select pg_temp.qv_add('Chopped Almonds with Milk Chocolate', 'bites', '100 G', 60);
select pg_temp.qv_add('Chopped Almonds with Dark Chocolate', 'bites', '100 G', 60);
select pg_temp.qv_add('Pistachio Dipped in White Chocolate', 'bites', '100 G', 60);
select pg_temp.qv_add('Pecan with Milk Chocolate', 'bites', '100 G', 60);
select pg_temp.qv_add('Hazelnut Dipped in Milk Chocolate', 'bites', '100 G', 60);
select pg_temp.qv_add('Pineapple Pâtes de Fruits', 'pates', '100 G', 60);
select pg_temp.qv_add('Guava Pâtes de Fruits', 'pates', '100 G', 60);

commit;

-- Check: nine lines, all 100 G at 60.
select p.category, p.name, v.name as size, v.price
from public.products p join public.product_variants v on v.product_id = p.id
where p.active and v.active and p.category in ('mendiant', 'bites', 'pates')
order by 1, 2;
