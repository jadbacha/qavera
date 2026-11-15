-- QAVERA: new menu (November 2026).
--   1. Slabs are QAR 80; new "Pretzel Slab".
--   2. Wrapped chocolate: Mendiant -> Rocher; new "Crunchy Lotus" and "Pecan Praline".
--   3. One box: "Chocolate Bonbons" (Mini 2 pcs QAR 15, 12 pcs QAR 100,
--      25 pcs QAR 210, 48 pcs QAR 390). Premium and Luxury are taken off sale
--      (kept in the database for past orders). Made to order: from tomorrow.
--   4. New category "Infused chocolate": Strawberry, Mango and Salted Caramel
--      Chocolate, 100 G, QAR 60.
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

-- 1. Slabs
update public.product_variants v set price = 80
  from public.products p
 where p.id = v.product_id and p.category = 'slabs';
select pg_temp.qv_add('Pretzel Slab', 'slabs', '100 G', 80);

-- 2. Wrapped chocolate
update public.products
   set name = regexp_replace(name, 'm[ae]ndiant', 'Rocher', 'gi')
 where name ~* 'm[ae]ndiant';
select pg_temp.qv_add('Crunchy Lotus', 'assorted', '1 KG', 380);
select pg_temp.qv_add('Pecan Praline', 'assorted', '1 KG', 380);

-- 3. One box: Chocolate Bonbons (no category, like the boxes before it)
select pg_temp.qv_add('Chocolate Bonbons', null, 'Mini', 15, 2);
select pg_temp.qv_add('Chocolate Bonbons', null, 'S', 100, 12);
select pg_temp.qv_add('Chocolate Bonbons', null, 'M', 210, 25);
select pg_temp.qv_add('Chocolate Bonbons', null, 'L', 390, 48);
update public.products set active = false where lower(trim(name)) in ('premium', 'luxury');

-- Boxes are made to order (earliest delivery tomorrow): add the new box to that rule.
do $patch$
declare
  r record;
  v_def text;
begin
  for r in
    select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.prosrc like '%in (''premium'', ''luxury'')%'
  loop
    v_def := pg_get_functiondef(r.oid);
    execute replace(v_def, 'in (''premium'', ''luxury'')', 'in (''premium'', ''luxury'', ''chocolate bonbons'')');
  end loop;
end
$patch$;

-- 4. Infused chocolate
select pg_temp.qv_add('Strawberry Chocolate', 'infused', '100 G', 60);
select pg_temp.qv_add('Mango Chocolate', 'infused', '100 G', 60);
select pg_temp.qv_add('Salted Caramel Chocolate', 'infused', '100 G', 60);

commit;

-- Check: everything on sale now.
select coalesce(p.category, 'box') as category, p.name, v.name as size, v.pieces, v.price
from public.products p join public.product_variants v on v.product_id = p.id
where p.active and v.active
order by 1, 2, v.price;
