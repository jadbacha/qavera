-- QAVERA: seasonal Chocolate Bonbons boxes, same 8 flavours (the customer chooses).
--   Christmas Box     25 pieces QAR 210 · 48 pieces QAR 390
--   National Day Box  25 pieces QAR 210 · 48 pieces QAR 390
-- On the website they show on the Chocolate Bonbons page until 31 December.
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

-- No category, like Chocolate Bonbons (shows under "Boxes").
select pg_temp.qv_add('Christmas Box', null, 'M', 210, 25);
select pg_temp.qv_add('Christmas Box', null, 'L', 390, 48);
select pg_temp.qv_add('National Day Box', null, 'M', 210, 25);
select pg_temp.qv_add('National Day Box', null, 'L', 390, 48);

commit;

-- Check: four rows.
select p.name, v.name as size, v.pieces, v.price
from public.products p join public.product_variants v on v.product_id = p.id
where p.name in ('Christmas Box', 'National Day Box') and v.active
order by p.name, v.price;
