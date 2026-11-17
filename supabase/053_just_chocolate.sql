-- QAVERA: new box "Just Chocolate" (plain milk chocolate, an even mix of
-- Hazelnuts, Pistachio, Pecan, Chocolate Gianduja and Lotus; the customer
-- does not choose flavours).
--   S = 12 pieces QAR 60 · M = 25 pieces QAR 160 · L = 48 pieces QAR 290
-- The website, the admin page and the till read it from here.
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

-- No category, like the Chocolate Bonbons box (shows under "Boxes").
select pg_temp.qv_add('Just Chocolate', null, 'S', 60, 12);
select pg_temp.qv_add('Just Chocolate', null, 'M', 160, 25);
select pg_temp.qv_add('Just Chocolate', null, 'L', 290, 48);

commit;

-- Check: three sizes, 12 / 25 / 48 pieces at 60 / 160 / 290.
select p.name, v.name as size, v.pieces, v.price
from public.products p join public.product_variants v on v.product_id = p.id
where lower(p.name) = 'just chocolate' and v.active
order by v.price;
