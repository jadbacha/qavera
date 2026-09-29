-- QAVERA: shop sales from the store POS app, and a 'staff' role.
-- Paste into Supabase SQL Editor and click Run. Safe to run more than once.
--
-- Shop sales are saved as orders with source = 'store'. They have no customer
-- account (user_id is null), so they never earn or use points, and they are
-- saved as already paid and delivered. The order emails skip them.
--
-- Roles: 'admin' (you) can do everything; 'staff' can only use the POS.
-- To add someone, they first create an account on the website, then run:
--   update public.profiles set role = 'staff' where lower(email) = lower('their@email.com');

begin;

-- 1. Extra details for shop sales.
alter table public.orders
  add column if not exists client_ref text,          -- id made by the POS, so a sale sent twice is saved once
  add column if not exists amount_received numeric,  -- cash handed over
  add column if not exists change_given numeric,
  add column if not exists created_by uuid;          -- staff member who made the sale

create unique index if not exists orders_client_ref_key
  on public.orders (client_ref) where client_ref is not null;

-- 2. Existing checks on orders (for example allowed payment methods) also accept shop sales.
do $$
declare
  c record;
begin
  for c in
    select con.conname, pg_get_constraintdef(con.oid) as def
    from pg_constraint con
    where con.conrelid = 'public.orders'::regclass
      and con.contype = 'c'
      and con.conname <> 'orders_status_check'
      and pg_get_constraintdef(con.oid) !~ 'source = ''store'''
  loop
    execute format('alter table public.orders drop constraint %I', c.conname);
    execute format(
      'alter table public.orders add constraint %I check ((%s) or (source = ''store''))',
      c.conname,
      regexp_replace(c.def, '^CHECK \((.*)\)( NOT VALID)?$', '\1')
    );
  end loop;
end;
$$;

-- 3. True for admins and staff.
create or replace function public.is_store_staff()
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid() and role in ('admin', 'staff')
  );
$$;

revoke execute on function public.is_store_staff() from public, anon;
grant execute on function public.is_store_staff() to authenticated;

-- 4. Save one shop sale. Prices always come from the database.
--    p_items: [{"variant_id": "...", "quantity": 2}, ...]
create or replace function public.create_store_sale(
  p_client_ref text,
  p_items jsonb,
  p_payment_method text,
  p_amount_received numeric,
  p_customer_name text,
  p_customer_phone text,
  p_sold_at timestamptz
)
returns table(order_id uuid, order_number text, total numeric, sold_at timestamptz)
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_order_id uuid;
  v_total numeric := 0;
  v_item jsonb;
  v_variant record;
  v_qty integer;
  v_sold_at timestamptz;
begin
  if not public.is_store_staff() then
    raise exception 'Only QAVERA staff can record shop sales';
  end if;

  if coalesce(trim(p_client_ref), '') = '' or char_length(p_client_ref) > 64 then
    raise exception 'Invalid sale reference';
  end if;

  -- Already saved (the POS retried after a lost connection): return the saved sale.
  if exists (select 1 from public.orders o where o.client_ref = p_client_ref) then
    return query
      select o.id, o.order_number, o.total, o.created_at
      from public.orders o where o.client_ref = p_client_ref;
    return;
  end if;

  if p_payment_method not in ('cash', 'card') then
    raise exception 'Invalid payment method';
  end if;

  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 or jsonb_array_length(p_items) > 50 then
    raise exception 'A sale needs between 1 and 50 items';
  end if;

  -- Sales made offline keep their real time (within the last 30 days).
  v_sold_at := case
    when p_sold_at is null or p_sold_at > now() + interval '5 minutes' or p_sold_at < now() - interval '30 days'
      then now()
    else p_sold_at
  end;

  for v_item in select value from jsonb_array_elements(p_items)
  loop
    if coalesce(v_item->>'quantity', '') !~ '^[0-9]{1,3}$' or (v_item->>'quantity')::integer < 1 then
      raise exception 'Invalid quantity';
    end if;

    select pv.price into v_variant
    from public.product_variants pv
    where pv.id = (v_item->>'variant_id')::uuid;

    if not found then
      raise exception 'Unknown product';
    end if;

    v_total := v_total + v_variant.price * (v_item->>'quantity')::integer;
  end loop;

  insert into public.orders (
    user_id, source, fulfillment_type, customer_name, customer_phone,
    subtotal, delivery_fee, total, status, payment_method, payment_status,
    client_ref, amount_received, change_given, created_by, created_at
  ) values (
    null, 'store', 'in_store',
    coalesce(nullif(trim(p_customer_name), ''), 'Walk-in customer'),
    coalesce(trim(p_customer_phone), ''),
    v_total, 0, v_total, 'delivered', p_payment_method, 'paid',
    p_client_ref,
    case when p_payment_method = 'cash' then coalesce(p_amount_received, v_total) else v_total end,
    case when p_payment_method = 'cash' then greatest(coalesce(p_amount_received, v_total) - v_total, 0) else 0 end,
    auth.uid(), v_sold_at
  )
  returning id into v_order_id;

  for v_item in select value from jsonb_array_elements(p_items)
  loop
    v_qty := (v_item->>'quantity')::integer;

    insert into public.order_items (order_id, variant_id, product_name, variant_name, unit_price, quantity, total_price)
    select v_order_id, pv.id, p.name, pv.name, pv.price, v_qty, pv.price * v_qty
    from public.product_variants pv
    join public.products p on p.id = pv.product_id
    where pv.id = (v_item->>'variant_id')::uuid;
  end loop;

  return query
    select o.id, o.order_number, o.total, o.created_at
    from public.orders o where o.id = v_order_id;
end;
$$;

revoke execute on function public.create_store_sale(text, jsonb, text, numeric, text, text, timestamptz) from public, anon;
grant execute on function public.create_store_sale(text, jsonb, text, numeric, text, text, timestamptz) to authenticated;

-- 5. Shop sales between two times, with their items (for the POS history).
create or replace function public.list_store_sales(p_from timestamptz, p_to timestamptz)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
begin
  if not public.is_store_staff() then
    raise exception 'Only QAVERA staff can view shop sales';
  end if;

  return coalesce((
    select jsonb_agg(sale order by sale->>'sold_at' desc)
    from (
      select jsonb_build_object(
        'id', o.id,
        'order_number', o.order_number,
        'client_ref', o.client_ref,
        'sold_at', o.created_at,
        'customer_name', o.customer_name,
        'customer_phone', o.customer_phone,
        'total', o.total,
        'payment_method', o.payment_method,
        'amount_received', o.amount_received,
        'change_given', o.change_given,
        'status', o.status,
        'items', coalesce((
          select jsonb_agg(jsonb_build_object(
            'product_name', i.product_name,
            'variant_name', i.variant_name,
            'unit_price', i.unit_price,
            'quantity', i.quantity,
            'total_price', i.total_price
          ) order by i.created_at)
          from public.order_items i where i.order_id = o.id
        ), '[]'::jsonb)
      ) as sale
      from public.orders o
      where o.source = 'store'
        and o.created_at >= p_from
        and o.created_at < p_to
      order by o.created_at desc
      limit 2000
    ) s
  ), '[]'::jsonb);
end;
$$;

revoke execute on function public.list_store_sales(timestamptz, timestamptz) from public, anon;
grant execute on function public.list_store_sales(timestamptz, timestamptz) to authenticated;

commit;

-- Check: your role, and the columns shop sales use.
select email, role from public.profiles where role in ('admin', 'staff');
