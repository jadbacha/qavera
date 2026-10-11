-- QAVERA: orders taken on WhatsApp or by phone, entered by an admin.
--   * Admin page → "New order": customer, products, delivery or pickup,
--     date and time, discount (%), delivery fee and payment.
--   * Saved like a website order (source 'whatsapp'), so it shows in
--     "To do" and moves through Confirm → Out for delivery → Delivered.
--   * Only admins can use it.
-- Paste into Supabase SQL Editor and click Run. Safe to run more than once.

begin;

create or replace function public.admin_create_order(
  p_customer_name text, p_customer_phone text,
  p_fulfillment text,
  p_delivery_area text, p_delivery_address text, p_building text, p_apartment text,
  p_scheduled_date date, p_time_slot text,
  p_items jsonb,
  p_discount_percent numeric, p_discount_reason text,
  p_delivery_fee numeric,
  p_payment_method text, p_notes text)
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

  if p_payment_method not in ('cash_on_delivery', 'card_on_delivery') then
    raise exception 'Invalid payment method';
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
    discount_amount, discount_reason, created_by
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
    auth.uid()
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

revoke execute on function public.admin_create_order(text, text, text, text, text, text, text, date, text, jsonb, numeric, text, numeric, text, text) from public, anon;
grant execute on function public.admin_create_order(text, text, text, text, text, text, text, date, text, jsonb, numeric, text, numeric, text, text) to authenticated;

commit;
