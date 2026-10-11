-- QAVERA: gift orders and Fawran payment.
--   * New payment method: Fawran (bank transfer to Qavera Trading, CR 237335),
--     paid in advance. The order waits for payment until an admin taps
--     "Fawran received" on the admin page.
--   * Gift orders: delivered to a recipient (name + phone) with an optional
--     message card. Gifts are always paid by Fawran.
--   * Same for the admin "New order" form.
--   Delivery charge stays QAR 25. Everything else is unchanged.
-- Paste into Supabase SQL Editor and click Run. Safe to run more than once.

begin;

alter table public.orders
  add column if not exists is_gift boolean not null default false,
  add column if not exists gift_recipient_name text,
  add column if not exists gift_recipient_phone text,
  add column if not exists gift_message text;

alter table public.orders drop constraint if exists orders_payment_method_check;
alter table public.orders add constraint orders_payment_method_check
  check (payment_method in ('cash_on_delivery', 'card_on_delivery', 'fawran') or source = 'store');

-- New versions take the gift details, so the old ones are replaced.
drop function if exists public.create_qavera_order(text, text, text, text, text, text, text, text, text, integer, boolean, text, jsonb, text, date, text);
drop function if exists public.admin_create_order(text, text, text, text, text, text, text, date, text, jsonb, numeric, text, numeric, text, text);

create or replace function public.create_qavera_order(p_customer_name text, p_customer_phone text, p_customer_email text, p_delivery_address text, p_delivery_area text, p_building text, p_apartment text, p_notes text, p_payment_method text, p_points_used integer, p_save_address boolean, p_address_label text, p_items jsonb,
  p_fulfillment text default 'delivery', p_scheduled_date date default null, p_time_slot text default null,
  p_gift boolean default false, p_gift_name text default null, p_gift_phone text default null, p_gift_message text default null)
 returns table(order_id uuid, order_number text, subtotal numeric, delivery_fee numeric, points_discount numeric, total numeric, points_used integer)
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_user_id uuid := auth.uid();
  v_subtotal numeric := 0;
  v_delivery numeric := 25;
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
  v_now_time time := (now() at time zone 'Asia/Qatar')::time;
  v_has_box boolean := false;
  v_gift boolean := coalesce(p_gift, false);
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

  -- Up to 30 days ahead. Same day is allowed except for Premium / Luxury
  -- boxes (made to order, from tomorrow); checked after reading the cart.
  if p_scheduled_date is null then
    raise exception 'Please choose a % date', case when v_pickup then 'pickup' else 'delivery' end;
  end if;

  if p_scheduled_date < v_today then
    raise exception 'Please choose a date from today';
  end if;

  if p_scheduled_date > v_today + 30 then
    raise exception 'Orders can be scheduled up to 30 days ahead';
  end if;

  if v_pickup and extract(isodow from p_scheduled_date) = 5 then
    if coalesce(p_time_slot, '') <> '13:00-18:00' then
      raise exception 'On Fridays pickup is 1 PM – 6 PM';
    end if;
  elsif v_pickup and coalesce(p_time_slot, '') not in ('10:00-14:00', '16:00-21:00') then
    raise exception 'Please choose a pickup time: 10 AM – 2 PM or 4 PM – 9 PM';
  end if;
  if not v_pickup and coalesce(p_time_slot, '') not in ('12:00-16:00', '18:00-23:00') then
    raise exception 'Please choose a delivery time: 12 PM – 4 PM or 6 PM – 11 PM';
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

  if p_payment_method not in ('cash_on_delivery', 'card_on_delivery', 'fawran') then
    raise exception 'Invalid payment method';
  end if;

  -- Gifts: delivered to someone else and paid in advance by Fawran.
  if v_gift then
    if v_pickup then
      raise exception 'Gifts are delivered. Please choose delivery.';
    end if;
    if nullif(trim(p_gift_name), '') is null or nullif(trim(p_gift_phone), '') is null then
      raise exception 'Please enter the recipient''s name and phone';
    end if;
    if p_payment_method <> 'fawran' then
      raise exception 'Gifts are paid in advance by Fawran';
    end if;
    if char_length(coalesce(p_gift_message, '')) > 300 then
      raise exception 'The gift message is too long (300 characters max)';
    end if;
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

    if lower(trim(v_variant.product_name)) in ('premium', 'luxury') then
      v_has_box := true;
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

  -- Boxes are made to order: from tomorrow.
  if v_has_box and p_scheduled_date < v_today + 1 then
    raise exception 'Premium and Luxury boxes are made to order. The earliest date is tomorrow.';
  end if;

  -- Same day: a time slot can be chosen until 1 hour before it starts.
  if p_scheduled_date = v_today
     and v_now_time >= (case p_time_slot
                          when '10:00-14:00' then time '09:00'
                          when '12:00-16:00' then time '11:00'
                          when '13:00-18:00' then time '12:00'
                          when '16:00-21:00' then time '15:00'
                          else time '17:00' end) then
    raise exception 'This time is no longer available today. Please choose a later time or another day.';
  end if;

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
    scheduled_date, time_slot,
    is_gift, gift_recipient_name, gift_recipient_phone, gift_message
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
    p_time_slot,
    v_gift,
    case when v_gift then trim(p_gift_name) end,
    case when v_gift then trim(p_gift_phone) end,
    case when v_gift then nullif(trim(p_gift_message), '') end
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

  if p_save_address and not v_pickup and not v_gift then
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


revoke execute on function public.create_qavera_order(text, text, text, text, text, text, text, text, text, integer, boolean, text, jsonb, text, date, text, boolean, text, text, text) from public, anon;
grant execute on function public.create_qavera_order(text, text, text, text, text, text, text, text, text, integer, boolean, text, jsonb, text, date, text, boolean, text, text, text) to authenticated;

create or replace function public.admin_create_order(
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
  v_pickup boolean := lower(coalesce(p_fulfillment, 'delivery')) = 'pickup';
  v_subtotal numeric := 0;
  v_discount numeric := 0;
  v_delivery numeric := 0;
  v_total numeric;
  v_order_id uuid;
  v_order_number text;
  v_item jsonb;
  v_variant record;
  v_qty integer;
  v_gift boolean := coalesce(p_gift, false);
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'Only QAVERA admins can add orders';
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

  if not v_pickup then
    if nullif(trim(p_delivery_area), '') is null or nullif(trim(p_delivery_address), '') is null then
      raise exception 'Delivery area and address are required';
    end if;
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

  for v_item in select value from jsonb_array_elements(p_items)
  loop
    v_qty := coalesce((v_item->>'quantity')::integer, 0);
    if v_qty <= 0 then
      raise exception 'Invalid item quantity';
    end if;

    select pv.price into v_variant
    from public.product_variants pv
    join public.products p on p.id = pv.product_id
    where pv.id = (v_item->>'variant_id')::uuid and pv.active and p.active;
    if not found then
      raise exception 'A product in this order is no longer available';
    end if;

    v_subtotal := v_subtotal + v_variant.price * v_qty;
  end loop;

  if coalesce(p_discount_percent, 0) < 0 or coalesce(p_discount_percent, 0) > 100 then
    raise exception 'Discount must be between 0 and 100%%';
  end if;
  v_discount := round(v_subtotal * coalesce(p_discount_percent, 0) / 100, 2);

  if not v_pickup then
    v_delivery := coalesce(p_delivery_fee, 25);
    if v_delivery < 0 then
      raise exception 'Invalid delivery fee';
    end if;
  end if;

  v_total := v_subtotal - v_discount + v_delivery;

  insert into public.orders (
    user_id, source, fulfillment_type, customer_name, customer_phone,
    delivery_address, delivery_area, subtotal, delivery_fee, total, status, notes,
    payment_method, payment_status, scheduled_date, time_slot,
    discount_amount, discount_reason, created_by,
    is_gift, gift_recipient_name, gift_recipient_phone, gift_message
  )
  values (
    null, 'whatsapp',
    case when v_pickup then 'pickup' else 'delivery' end,
    trim(p_customer_name), trim(p_customer_phone),
    case when v_pickup then 'Pickup from the QAVERA shop'
         else trim(p_delivery_address)
              || coalesce(E'\nBuilding / Villa: ' || nullif(trim(p_building), ''), '')
              || coalesce(E'\nApartment / Floor: ' || nullif(trim(p_apartment), ''), '') end,
    case when v_pickup then null else trim(p_delivery_area) end,
    v_subtotal, v_delivery, v_total, 'confirmed', nullif(trim(p_notes), ''),
    p_payment_method, 'pending', p_scheduled_date, p_time_slot,
    v_discount,
    case when v_discount > 0
         then coalesce(nullif(left(trim(coalesce(p_discount_reason, '')), 120), ''), trim(to_char(p_discount_percent, 'FM990.##')) || '% off')
    end,
    auth.uid(),
    v_gift,
    case when v_gift then trim(p_gift_name) end,
    case when v_gift then trim(p_gift_phone) end,
    case when v_gift then nullif(left(trim(coalesce(p_gift_message, '')), 300), '') end
  )
  returning id, orders.order_number into v_order_id, v_order_number;

  for v_item in select value from jsonb_array_elements(p_items)
  loop
    v_qty := (v_item->>'quantity')::integer;
    insert into public.order_items (order_id, variant_id, product_name, variant_name, unit_price, quantity, total_price, customization)
    select v_order_id, pv.id, p.name, pv.name, pv.price, v_qty, pv.price * v_qty, null
    from public.product_variants pv
    join public.products p on p.id = pv.product_id
    where pv.id = (v_item->>'variant_id')::uuid;
  end loop;

  return query select v_order_id, v_order_number, v_total;
end;
$function$;


revoke execute on function public.admin_create_order(text, text, text, text, text, text, text, date, text, jsonb, numeric, text, numeric, text, text, boolean, text, text, text) from public, anon;
grant execute on function public.admin_create_order(text, text, text, text, text, text, text, date, text, jsonb, numeric, text, numeric, text, text, boolean, text, text, text) to authenticated;

-- Admin: mark a Fawran order as paid (or undo it).
create or replace function public.admin_set_payment_status(p_order_id uuid, p_paid boolean)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'Only QAVERA admins can change payments';
  end if;
  update public.orders
     set payment_status = case when p_paid then 'paid' else 'pending' end
   where id = p_order_id and source <> 'store';
  if not found then
    raise exception 'Order not found';
  end if;
end;
$function$;

revoke execute on function public.admin_set_payment_status(uuid, boolean) from public, anon;
grant execute on function public.admin_set_payment_status(uuid, boolean) to authenticated;

commit;
