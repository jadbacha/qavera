-- QAVERA: choose delivery or pickup, a date and a time slot at checkout.
-- Paste into Supabase SQL Editor and click Run. Safe to run more than once.
--
--   * Date: from tomorrow (Qatar time) up to 30 days ahead. No same-day orders.
--   * Time: '12:00-16:00' (12 PM – 4 PM) or '18:00-23:00' (6 PM – 11 PM).
--   * Pickup: collected from the shop, no delivery fee, no address needed.
-- Shop sales from the POS are not affected.

begin;

-- 1. Where the choice is saved.
alter table public.orders
  add column if not exists scheduled_date date,
  add column if not exists time_slot text;

alter table public.orders drop constraint if exists orders_time_slot_check;
alter table public.orders add constraint orders_time_slot_check
  check (time_slot is null or time_slot in ('12:00-16:00', '18:00-23:00'));

-- 2. Existing checks on fulfillment_type (if any) also accept 'pickup'.
do $$
declare
  c record;
begin
  for c in
    select con.conname, pg_get_constraintdef(con.oid) as def
    from pg_constraint con
    where con.conrelid = 'public.orders'::regclass
      and con.contype = 'c'
      and pg_get_constraintdef(con.oid) ~ 'fulfillment_type'
      and pg_get_constraintdef(con.oid) !~ 'pickup'
  loop
    execute format('alter table public.orders drop constraint %I', c.conname);
    execute format(
      'alter table public.orders add constraint %I check ((%s) or (fulfillment_type = ''pickup''))',
      c.conname,
      regexp_replace(c.def, '^CHECK \((.*)\)( NOT VALID)?$', '\1')
    );
  end loop;
end;
$$;

-- 3. The checkout function, now with fulfilment, date and time slot.
--    The old version (without them) is removed so there is only one.
drop function if exists public.create_qavera_order(text, text, text, text, text, text, text, text, text, integer, boolean, text, jsonb);

create or replace function public.create_qavera_order(p_customer_name text, p_customer_phone text, p_customer_email text, p_delivery_address text, p_delivery_area text, p_building text, p_apartment text, p_notes text, p_payment_method text, p_points_used integer, p_save_address boolean, p_address_label text, p_items jsonb,
  p_fulfillment text default 'delivery', p_scheduled_date date default null, p_time_slot text default null)
 returns table(order_id uuid, order_number text, subtotal numeric, delivery_fee numeric, points_discount numeric, total numeric, points_used integer)
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_user_id uuid := auth.uid();
  v_subtotal numeric := 0;
  v_delivery numeric := 20;
  v_discount numeric := 0;
  v_total numeric := 0;
  v_points integer := 0;
  v_order_id uuid;
  v_order_number text;
  v_item jsonb;
  v_variant record;
  v_qty integer;
  v_line_total numeric;
  v_flavors jsonb;
  v_flavor jsonb;
  v_flavor_total integer;
  v_flavor_qty integer;
  v_pickup boolean := lower(coalesce(p_fulfillment, 'delivery')) = 'pickup';
  v_today date := (now() at time zone 'Asia/Qatar')::date;  -- today in Qatar
begin
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  if nullif(trim(p_customer_name), '') is null then
    raise exception 'Customer name is required';
  end if;

  if nullif(trim(p_customer_phone), '') is null then
    raise exception 'Customer phone is required';
  end if;

  if lower(coalesce(p_fulfillment, 'delivery')) not in ('delivery', 'pickup') then
    raise exception 'Choose delivery or pickup';
  end if;

  -- Chocolates are made to order: from tomorrow (Qatar time), up to 30 days ahead.
  if p_scheduled_date is null then
    raise exception 'Please choose a % date', case when v_pickup then 'pickup' else 'delivery' end;
  end if;

  if p_scheduled_date < v_today + 1 then
    raise exception 'The earliest date is tomorrow, as every order is prepared by hand';
  end if;

  if p_scheduled_date > v_today + 30 then
    raise exception 'Orders can be scheduled up to 30 days ahead';
  end if;

  if coalesce(p_time_slot, '') not in ('12:00-16:00', '18:00-23:00') then
    raise exception 'Please choose a time: 12 PM – 4 PM or 6 PM – 11 PM';
  end if;

  if not v_pickup then
    if nullif(trim(p_delivery_area), '') is null then
      raise exception 'Delivery area is required';
    end if;

    if nullif(trim(p_delivery_address), '') is null then
      raise exception 'Delivery address is required';
    end if;

    if nullif(trim(p_building), '') is null then
      raise exception 'Building / villa number is required';
    end if;

    if nullif(trim(p_apartment), '') is null then
      raise exception 'Apartment / floor is required';
    end if;
  end if;

  if p_payment_method not in ('cash_on_delivery', 'card_on_delivery') then
    raise exception 'Invalid payment method';
  end if;

  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'Cart is empty';
  end if;

  for v_item in select value from jsonb_array_elements(p_items)
  loop
    if nullif(v_item->>'variant_id', '') is null then
      raise exception 'Every cart item must have a product variant';
    end if;

    v_qty := coalesce((v_item->>'quantity')::integer, 0);
    if v_qty <= 0 then
      raise exception 'Invalid item quantity';
    end if;

    select pv.id, pv.name, pv.price, pv.pieces, p.name as product_name
      into v_variant
    from public.product_variants pv
    join public.products p on p.id = pv.product_id
    where pv.id = (v_item->>'variant_id')::uuid
      and pv.active = true
      and p.active = true;

    if not found then
      raise exception 'A product in your cart is no longer available';
    end if;

    v_flavors := v_item->'flavors';
    if v_flavors is not null and jsonb_typeof(v_flavors) <> 'null' then
      if v_variant.pieces is null then
        raise exception '% cannot be customized', v_variant.product_name;
      end if;
      if jsonb_typeof(v_flavors) <> 'array' or jsonb_array_length(v_flavors) > 20 then
        raise exception 'Invalid flavour selection';
      end if;

      v_flavor_total := 0;
      for v_flavor in select value from jsonb_array_elements(v_flavors)
      loop
        if jsonb_typeof(v_flavor) <> 'object'
           or nullif(trim(v_flavor->>'name'), '') is null
           or char_length(v_flavor->>'name') > 60
           or coalesce(v_flavor->>'quantity', '') !~ '^[0-9]{1,3}$' then
          raise exception 'Invalid flavour selection';
        end if;
        v_flavor_qty := (v_flavor->>'quantity')::integer;
        v_flavor_total := v_flavor_total + v_flavor_qty;
      end loop;

      if v_flavor_total <> v_variant.pieces then
        raise exception 'Your customized box must contain exactly % pieces', v_variant.pieces;
      end if;
    end if;

    v_line_total := v_variant.price * v_qty;
    v_subtotal := v_subtotal + v_line_total;
  end loop;

  v_points := greatest(coalesce(p_points_used, 0), 0);

  if v_points > 0 and mod(v_points, 100) <> 0 then
    raise exception 'Points can only be redeemed in 100-point blocks';
  end if;

  if v_points > floor(v_subtotal * 10 / 100) * 100 then
    raise exception 'Too many points for this order';
  end if;

  if v_points > 0 then
    perform 1
    from public.profiles
    where id = v_user_id
      and points >= v_points
    for update;

    if not found then
      raise exception 'Insufficient QAVERA points';
    end if;

    v_discount := v_points / 10.0;
  end if;

  if v_pickup then
    v_delivery := 0;  -- collected from the shop
  end if;

  v_total := v_subtotal - v_discount + v_delivery;

  insert into public.orders (
    user_id, source, fulfillment_type, customer_name, customer_phone, customer_email,
    delivery_address, delivery_area, subtotal, delivery_fee, total, status, notes,
    payment_method, payment_status, points_used, points_discount,
    scheduled_date, time_slot
  )
  values (
    v_user_id,
    'website',
    case when v_pickup then 'pickup' else 'delivery' end,
    trim(p_customer_name),
    trim(p_customer_phone),
    nullif(trim(p_customer_email), ''),
    case when v_pickup then 'Pickup from the QAVERA shop'
         else trim(p_delivery_address) || E'\nBuilding / Villa: ' || trim(p_building) || E'\nApartment / Floor: ' || trim(p_apartment) end,
    case when v_pickup then null else trim(p_delivery_area) end,
    v_subtotal,
    v_delivery,
    v_total,
    'pending',
    nullif(trim(p_notes), ''),
    p_payment_method,
    'pending',
    v_points,
    v_discount,
    p_scheduled_date,
    p_time_slot
  )
  returning id, orders.order_number into v_order_id, v_order_number;

  for v_item in select value from jsonb_array_elements(p_items)
  loop
    select pv.id, pv.name, pv.price, p.name as product_name
      into v_variant
    from public.product_variants pv
    join public.products p on p.id = pv.product_id
    where pv.id = (v_item->>'variant_id')::uuid
      and pv.active = true
      and p.active = true;

    v_qty := (v_item->>'quantity')::integer;

    v_flavors := v_item->'flavors';
    if v_flavors is not null and jsonb_typeof(v_flavors) = 'array' then
      -- Keep only name + quantity for flavours actually chosen.
      select jsonb_agg(jsonb_build_object('name', trim(f->>'name'), 'quantity', (f->>'quantity')::integer))
        into v_flavors
      from jsonb_array_elements(v_flavors) f
      where (f->>'quantity')::integer > 0;
    else
      v_flavors := null;
    end if;

    insert into public.order_items (
      order_id, variant_id, product_name, variant_name, unit_price, quantity, total_price, customization
    )
    values (
      v_order_id,
      v_variant.id,
      v_variant.product_name,
      v_variant.name,
      v_variant.price,
      v_qty,
      v_variant.price * v_qty,
      v_flavors
    );
  end loop;

  if v_points > 0 then
    update public.profiles
    set points = points - v_points
    where id = v_user_id;
  end if;

  if p_save_address and not v_pickup then
    insert into public.addresses (user_id, label, full_address, area, phone, is_default)
    values (
      v_user_id,
      coalesce(nullif(trim(p_address_label), ''), 'Home'),
      trim(p_delivery_address) || E'\nBuilding / Villa: ' || trim(p_building) || E'\nApartment / Floor: ' || trim(p_apartment),
      trim(p_delivery_area),
      trim(p_customer_phone),
      not exists (select 1 from public.addresses a where a.user_id = v_user_id)
    );
  end if;

  return query select v_order_id, v_order_number, v_subtotal, v_delivery, v_discount, v_total, v_points;
end;
$function$;

revoke execute on function public.create_qavera_order(text, text, text, text, text, text, text, text, text, integer, boolean, text, jsonb, text, date, text) from public, anon;
grant execute on function public.create_qavera_order(text, text, text, text, text, text, text, text, text, integer, boolean, text, jsonb, text, date, text) to authenticated;

commit;

-- Check: should show the new columns.
select column_name, data_type from information_schema.columns
where table_name = 'orders' and column_name in ('scheduled_date', 'time_slot');
