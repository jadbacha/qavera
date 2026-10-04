-- QAVERA: admins can mark products out of stock.
--   * products.in_stock (true by default).
--   * admin_set_product_stock(product, true/false): admins only.
--   * Website orders with a sold-out product are refused by the database,
--     even from an old cart. Shop till sales are always accepted, because the
--     till may send a sale made offline before the product ran out.
-- Paste into Supabase SQL Editor and click Run. Safe to run more than once.

begin;

alter table public.products
  add column if not exists in_stock boolean not null default true;

create or replace function public.admin_set_product_stock(p_product_id uuid, p_in_stock boolean)
returns table(id uuid, name text, in_stock boolean)
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if not public.is_admin() then
    raise exception 'Only QAVERA admins can change stock';
  end if;

  return query
    update public.products p
    set in_stock = coalesce(p_in_stock, true)
    where p.id = p_product_id
    returning p.id, p.name, p.in_stock;

  if not found then
    raise exception 'Product not found';
  end if;
end;
$$;

revoke execute on function public.admin_set_product_stock(uuid, boolean) from public, anon;
grant execute on function public.admin_set_product_stock(uuid, boolean) to authenticated;

-- Refuse sold-out products on website orders.
create or replace function public.check_item_in_stock()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_name text;
  v_in_stock boolean;
begin
  if exists (select 1 from public.orders o where o.id = new.order_id and o.source = 'store') then
    return new;
  end if;

  select p.name, p.in_stock into v_name, v_in_stock
  from public.product_variants v
  join public.products p on p.id = v.product_id
  where v.id = new.variant_id;

  if v_in_stock is false then
    raise exception '% is sold out. Please remove it from your cart.', v_name;
  end if;

  return new;
end;
$$;

drop trigger if exists order_items_in_stock on public.order_items;
create trigger order_items_in_stock
  before insert on public.order_items
  for each row execute function public.check_item_in_stock();

commit;

-- Check: every product on sale and whether it is in stock.
select name, in_stock from public.products where active order by category nulls first, name;
