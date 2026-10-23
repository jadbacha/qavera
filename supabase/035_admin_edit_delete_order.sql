-- QAVERA: admins can edit or delete an order from the admin page.
--   * admin_delete_order: deletes the order and its products, gives back any
--     points it gave or used, and lets the numbering continue from the
--     highest remaining order.
--   * admin_update_order: changes customer, delivery / pickup, date and time,
--     products (with box flavours), discount, delivery charge, payment, notes
--     and gift details. Totals are worked out again; points used stay.
--     Order number, status and where it came from do not change.
-- Paste into Supabase SQL Editor and click Run. Safe to run more than once.

begin;

create or replace function public.admin_delete_order(p_order_id uuid)
 returns text
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  o record;
  v_last integer;
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'Only QAVERA admins can delete orders';
  end if;

  select * into o from public.orders where id = p_order_id;
  if not found then
    raise exception 'Order not found';
  end if;

  -- Undo any points on the account that placed it.
  if o.user_id is not null then
    if o.status = 'delivered' and coalesce(o.points_earned, 0) > 0 then
      update public.profiles set points = greatest(points - o.points_earned, 0) where id = o.user_id;
    end if;
    if o.status <> 'cancelled' and coalesce(o.points_used, 0) > 0 then
      update public.profiles set points = points + o.points_used where id = o.user_id;
    end if;
  end if;

  delete from public.order_items where order_id = o.id;
  delete from public.orders where id = o.id;

  -- The next order gets the number right after the highest remaining one.
  select coalesce(max(substring(order_number from 5)::integer), 0) into v_last
  from public.orders where order_number ~ '^QAV-[0-9]+$';
  perform setval('public.order_number_seq', greatest(v_last, 1), v_last > 0);

  return o.order_number;
end;
$function$;

revoke execute on function public.admin_delete_order(uuid) from public, anon;
grant execute on function public.admin_delete_order(uuid) to authenticated;


create or replace function public.admin_update_order(
  p_order_id uuid,
  p_customer_name text, p_customer_phone text,
  p_fulfillment text,
  p_delivery_area text, p_delivery_address text, p_building text, p_apartment text,
  p_scheduled_date date, p_time_slot text,
  p_items jsonb,
  p_discount_percent numeric, p_discount_reason text,
  p_delivery_fee numeric,
  p_payment_method text, p_notes text,
  p_gift boolean default false, p_gift_name text default null, p_gift_phone text default null, p_gift_message text default null)
 returns table(order_id uuid, order_number text, total numeric)
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  o record;
  v_pickup boolean := lower(coalesce(p_fulfillment, 'delivery')) = 'pickup';
  v_gift boolean := coalesce(p_gift, false);
  v_subtotal numeric := 0;
  v_discount numeric := 0;
  v_delivery numeric := 0;
  v_total numeric;
  v_item jsonb;
  v_variant record;
  v_qty integer;
  v_flavors jsonb;
  v_new_items jsonb := '[]'::jsonb;
  v_old_key text;
  v_new_key text;
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'Only QAVERA admins can edit orders';
  end if;

  select * into o from public.orders where id = p_order_id for update;
  if not found then
    raise exception 'Order not found';
  end if;
  if o.source = 'store' then
    raise exception 'Shop sales from the till cannot be edited here';
  end if;

  if nullif(trim(p_customer_name), '') is null then
    raise exception 'Customer name is required';
  end if;
  if nullif(trim(p_customer_phone), '') is null then
    raise exception 'Customer phone is required';
  end if;
  if lower(coalesce(p_fulfillment, '')) not in ('delivery', 'pickup') then
    raise exception 'Choose delivery or pickup';
  end if;
  if p_scheduled_date is null then
    raise exception 'Please choose a date';
  end if;
  if v_pickup and extract(isodow from p_scheduled_date) = 5 then
    if coalesce(p_time_slot, '') <> '13:00-18:00' then
      raise exception 'On Fridays pickup is 1 PM – 6 PM';
    end if;
  elsif v_pickup and coalesce(p_time_slot, '') not in ('10:00-14:00', '16:00-21:00') then
    raise exception 'Please choose a pickup time';
  elsif not v_pickup and coalesce(p_time_slot, '') not in ('12:00-16:00', '18:00-23:00') then
    raise exception 'Please choose a delivery time';
  end if;
  if not v_pickup and (nullif(trim(p_delivery_area), '') is null or nullif(trim(p_delivery_address), '') is null) then
    raise exception 'Delivery area and address are required';
  end if;
  if p_payment_method not in ('cash_on_delivery', 'card_on_delivery', 'fawran') then
    raise exception 'Invalid payment method';
  end if;
  if v_gift then
    if v_pickup then
      raise exception 'Gifts are delivered. Please choose delivery.';
    end if;
    if nullif(trim(p_gift_name), '') is null or nullif(trim(p_gift_phone), '') is null then
      raise exception 'Please enter the recipient''s name and phone';
    end if;
  end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'Add at least one product';
  end if;

  -- Products: price from the catalogue, flavours must fill the box.
  for v_item in select value from jsonb_array_elements(p_items)
  loop
    v_qty := coalesce((v_item->>'quantity')::integer, 0);
    if v_qty <= 0 then
      raise exception 'Invalid item quantity';
    end if;

    select pv.id, pv.price, pv.pieces into v_variant
    from public.product_variants pv
    where pv.id = (v_item->>'variant_id')::uuid;
    if not found then
      raise exception 'A product in this order no longer exists';
    end if;

    v_flavors := null;
    if jsonb_typeof(v_item->'flavors') = 'array' then
      select jsonb_agg(jsonb_build_object('name', left(trim(f->>'name'), 60), 'quantity', (f->>'quantity')::integer))
        into v_flavors
      from jsonb_array_elements(v_item->'flavors') f
      where coalesce(f->>'quantity', '') ~ '^[0-9]{1,3}$' and (f->>'quantity')::integer > 0
        and nullif(trim(f->>'name'), '') is not null;
      if v_flavors is not null and (v_variant.pieces is null
         or (select sum((f->>'quantity')::integer) from jsonb_array_elements(v_flavors) f) <> v_variant.pieces) then
        raise exception 'The flavours must add up to % pieces', coalesce(v_variant.pieces, 0);
      end if;
    end if;

    v_subtotal := v_subtotal + v_variant.price * v_qty;
    v_new_items := v_new_items || jsonb_build_array(jsonb_build_object(
      'variant_id', v_variant.id, 'quantity', v_qty, 'flavors', v_flavors));
  end loop;

  if coalesce(p_discount_percent, 0) < 0 or coalesce(p_discount_percent, 0) > 100 then
    raise exception 'Discount must be between 0 and 100%%';
  end if;
  v_discount := round(v_subtotal * coalesce(p_discount_percent, 0) / 100, 2);

  if not v_pickup then
    v_delivery := coalesce(p_delivery_fee, 0);
    if v_delivery < 0 then
      raise exception 'Invalid delivery fee';
    end if;
  end if;

  -- Points used on the original order still count.
  v_total := v_subtotal - v_discount - coalesce(o.points_discount, 0) + v_delivery;
  if v_total < 0 then
    raise exception 'The total cannot be below zero';
  end if;

  -- Replace the products only if they changed (so a product that has since
  -- sold out does not block editing the address or the time).
  select string_agg(k, ';' order by k) into v_old_key
  from (select format('%s|%s|%s', i.variant_id, i.quantity, coalesce(i.customization::text, '')) as k
        from public.order_items i where i.order_id = o.id) old_items;
  select string_agg(k, ';' order by k) into v_new_key
  from (select format('%s|%s|%s', x->>'variant_id', x->>'quantity',
                      case when jsonb_typeof(x->'flavors') = 'array' then (x->'flavors')::text else '' end) as k
        from jsonb_array_elements(v_new_items) x) new_items;

  if coalesce(v_old_key, '') <> coalesce(v_new_key, '') then
    delete from public.order_items where order_items.order_id = o.id;
    for v_item in select value from jsonb_array_elements(v_new_items)
    loop
      insert into public.order_items (order_id, variant_id, product_name, variant_name, unit_price, quantity, total_price, customization)
      select o.id, pv.id, p.name, pv.name, pv.price, (v_item->>'quantity')::integer,
             pv.price * (v_item->>'quantity')::integer,
             case when jsonb_typeof(v_item->'flavors') = 'array' then v_item->'flavors' end
      from public.product_variants pv
      join public.products p on p.id = pv.product_id
      where pv.id = (v_item->>'variant_id')::uuid;
    end loop;
  end if;

  update public.orders set
    customer_name = trim(p_customer_name),
    customer_phone = trim(p_customer_phone),
    fulfillment_type = case when v_pickup then 'pickup' else 'delivery' end,
    delivery_address = case when v_pickup then 'Pickup from the QAVERA shop'
         else trim(p_delivery_address)
              || coalesce(E'\nBuilding / Villa: ' || nullif(trim(p_building), ''), '')
              || coalesce(E'\nApartment / Floor: ' || nullif(trim(p_apartment), ''), '') end,
    delivery_area = case when v_pickup then null else trim(p_delivery_area) end,
    scheduled_date = p_scheduled_date,
    time_slot = p_time_slot,
    subtotal = v_subtotal,
    discount_amount = v_discount,
    discount_reason = case when v_discount > 0
         then coalesce(nullif(left(trim(coalesce(p_discount_reason, '')), 120), ''), trim(to_char(p_discount_percent, 'FM990.##')) || '% off')
    end,
    delivery_fee = v_delivery,
    total = v_total,
    payment_method = p_payment_method,
    notes = nullif(trim(p_notes), ''),
    is_gift = v_gift,
    gift_recipient_name = case when v_gift then trim(p_gift_name) end,
    gift_recipient_phone = case when v_gift then trim(p_gift_phone) end,
    gift_message = case when v_gift then nullif(left(trim(coalesce(p_gift_message, '')), 300), '') end
  where id = o.id;

  return query select o.id, o.order_number, v_total;
end;
$function$;

revoke execute on function public.admin_update_order(uuid, text, text, text, text, text, text, text, date, text, jsonb, numeric, text, numeric, text, text, boolean, text, text, text) from public, anon;
grant execute on function public.admin_update_order(uuid, text, text, text, text, text, text, text, date, text, jsonb, numeric, text, numeric, text, text, boolean, text, text, text) to authenticated;

commit;
