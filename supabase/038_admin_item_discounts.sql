-- QAVERA: admin "New order" / "Edit order" discounts, like the till.
--   * Each product line can have its own discount: % of the line or QAR off.
--     Items send "discount_mode" ('percent' or 'amount') and "discount_value".
--   * The discount on the whole bill can be a % (p_discount_percent) or a QAR
--     amount (p_discount_amount); it applies after the item discounts.
--   * Each line keeps its discount (order_items.discount_amount / discount_label)
--     so receipts can show it; the order's discount_amount is the total.
-- Paste into Supabase SQL Editor and click Run. Safe to run more than once.

begin;

alter table public.order_items
  add column if not exists discount_amount numeric not null default 0,
  add column if not exists discount_label text;

-- One line's discount: % of the line or QAR off, never more than the line.
create or replace function public.qavera_line_discount(p_item jsonb, p_line numeric)
 returns numeric
 language plpgsql
 immutable
 set search_path to 'public'
as $function$
declare
  v_mode text := lower(coalesce(p_item->>'discount_mode', 'percent'));
  v_value numeric;
begin
  begin
    v_value := coalesce(nullif(trim(p_item->>'discount_value'), '')::numeric, 0);
  exception when others then
    raise exception 'Invalid item discount';
  end;
  if v_value < 0 then raise exception 'Invalid item discount'; end if;
  if v_value = 0 then return 0; end if;
  if v_mode = 'amount' then
    return round(least(v_value, p_line), 2);
  elsif v_mode = 'percent' then
    if v_value > 100 then raise exception 'An item discount can be at most 100%%'; end if;
    return round(p_line * v_value / 100, 2);
  end if;
  raise exception 'Invalid item discount';
end;
$function$;

create or replace function public.qavera_line_discount_label(p_item jsonb)
 returns text
 language sql
 immutable
as $function$
  select case when lower(coalesce(p_item->>'discount_mode', 'percent')) = 'amount'
              then trim(to_char(nullif(trim(p_item->>'discount_value'), '')::numeric, 'FM999990.##')) || ' QAR off'
              else trim(to_char(nullif(trim(p_item->>'discount_value'), '')::numeric, 'FM990.##')) || '% off' end;
$function$;


-- ---------------------------------------------------------------- new order
drop function if exists public.admin_create_order(text, text, text, text, text, text, text, date, text, jsonb, numeric, text, numeric, text, text, boolean, text, text, text);

create or replace function public.admin_create_order(
  p_customer_name text, p_customer_phone text,
  p_fulfillment text,
  p_delivery_area text, p_delivery_address text, p_building text, p_apartment text,
  p_scheduled_date date, p_time_slot text,
  p_items jsonb,
  p_discount_percent numeric, p_discount_reason text,
  p_delivery_fee numeric,
  p_payment_method text, p_notes text,
  p_gift boolean default false, p_gift_name text default null, p_gift_phone text default null, p_gift_message text default null,
  p_discount_amount numeric default null)
 returns table(order_id uuid, order_number text, total numeric)
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_pickup boolean := lower(coalesce(p_fulfillment, 'delivery')) = 'pickup';
  v_gift boolean := coalesce(p_gift, false);
  v_subtotal numeric := 0;
  v_item_discounts numeric := 0;
  v_bill_discount numeric := 0;
  v_discount numeric := 0;
  v_delivery numeric := 0;
  v_total numeric;
  v_order_id uuid;
  v_order_number text;
  v_item jsonb;
  v_variant record;
  v_qty integer;
  v_flavors jsonb;
  v_line_discount numeric;
  v_lines jsonb := '[]'::jsonb;
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

  -- Products: price from the catalogue, flavours must fill the box, own discount.
  for v_item in select value from jsonb_array_elements(p_items)
  loop
    v_qty := coalesce((v_item->>'quantity')::integer, 0);
    if v_qty <= 0 then
      raise exception 'Invalid item quantity';
    end if;
    select pv.id, pv.price, pv.pieces into v_variant
    from public.product_variants pv
    join public.products p on p.id = pv.product_id
    where pv.id = (v_item->>'variant_id')::uuid and pv.active and p.active;
    if not found then
      raise exception 'A product in this order is no longer available';
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

    v_line_discount := public.qavera_line_discount(v_item, v_variant.price * v_qty);
    v_subtotal := v_subtotal + v_variant.price * v_qty;
    v_item_discounts := v_item_discounts + v_line_discount;
    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'variant_id', v_variant.id, 'quantity', v_qty, 'flavors', v_flavors,
      'discount', v_line_discount, 'label', case when v_line_discount > 0 then public.qavera_line_discount_label(v_item) end));
  end loop;

  -- Discount on the whole bill (after item discounts): QAR, or else %.
  if p_discount_amount is not null then
    if p_discount_amount < 0 then raise exception 'Invalid discount'; end if;
    v_bill_discount := round(least(p_discount_amount, v_subtotal - v_item_discounts), 2);
  else
    if coalesce(p_discount_percent, 0) < 0 or coalesce(p_discount_percent, 0) > 100 then
      raise exception 'Discount must be between 0 and 100%%';
    end if;
    v_bill_discount := round((v_subtotal - v_item_discounts) * coalesce(p_discount_percent, 0) / 100, 2);
  end if;
  v_discount := v_item_discounts + v_bill_discount;

  if not v_pickup then
    v_delivery := coalesce(p_delivery_fee, 0);
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
    case when v_discount > 0 then coalesce(nullif(left(trim(coalesce(p_discount_reason, '')), 120), ''),
      case when v_bill_discount > 0 and p_discount_amount is not null then trim(to_char(p_discount_amount, 'FM999990.##')) || ' QAR off'
           when v_bill_discount > 0 then trim(to_char(p_discount_percent, 'FM990.##')) || '% off'
           else 'Item discounts' end) end,
    auth.uid(),
    v_gift,
    case when v_gift then trim(p_gift_name) end,
    case when v_gift then trim(p_gift_phone) end,
    case when v_gift then nullif(left(trim(coalesce(p_gift_message, '')), 300), '') end
  )
  returning id, orders.order_number into v_order_id, v_order_number;

  for v_item in select value from jsonb_array_elements(v_lines)
  loop
    insert into public.order_items (order_id, variant_id, product_name, variant_name, unit_price, quantity, total_price, customization, discount_amount, discount_label)
    select v_order_id, pv.id, p.name, pv.name, pv.price, (v_item->>'quantity')::integer,
           pv.price * (v_item->>'quantity')::integer,
           case when jsonb_typeof(v_item->'flavors') = 'array' then v_item->'flavors' end,
           (v_item->>'discount')::numeric, v_item->>'label'
    from public.product_variants pv
    join public.products p on p.id = pv.product_id
    where pv.id = (v_item->>'variant_id')::uuid;
  end loop;

  return query select v_order_id, v_order_number, v_total;
end;
$function$;

revoke execute on function public.admin_create_order(text, text, text, text, text, text, text, date, text, jsonb, numeric, text, numeric, text, text, boolean, text, text, text, numeric) from public, anon;
grant execute on function public.admin_create_order(text, text, text, text, text, text, text, date, text, jsonb, numeric, text, numeric, text, text, boolean, text, text, text, numeric) to authenticated;


-- --------------------------------------------------------------- edit order
drop function if exists public.admin_update_order(uuid, text, text, text, text, text, text, text, date, text, jsonb, numeric, text, numeric, text, text, boolean, text, text, text);

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
  p_gift boolean default false, p_gift_name text default null, p_gift_phone text default null, p_gift_message text default null,
  p_discount_amount numeric default null)
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
  v_item_discounts numeric := 0;
  v_bill_discount numeric := 0;
  v_discount numeric := 0;
  v_delivery numeric := 0;
  v_total numeric;
  v_item jsonb;
  v_variant record;
  v_qty integer;
  v_flavors jsonb;
  v_line_discount numeric;
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
  if p_payment_method not in ('cash_on_delivery', 'card_on_delivery', 'fawran', 'card_online') then
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

    v_line_discount := public.qavera_line_discount(v_item, v_variant.price * v_qty);
    v_subtotal := v_subtotal + v_variant.price * v_qty;
    v_item_discounts := v_item_discounts + v_line_discount;
    v_new_items := v_new_items || jsonb_build_array(jsonb_build_object(
      'variant_id', v_variant.id, 'quantity', v_qty, 'flavors', v_flavors,
      'discount', v_line_discount, 'label', case when v_line_discount > 0 then public.qavera_line_discount_label(v_item) end));
  end loop;

  if p_discount_amount is not null then
    if p_discount_amount < 0 then raise exception 'Invalid discount'; end if;
    v_bill_discount := round(least(p_discount_amount, v_subtotal - v_item_discounts), 2);
  else
    if coalesce(p_discount_percent, 0) < 0 or coalesce(p_discount_percent, 0) > 100 then
      raise exception 'Discount must be between 0 and 100%%';
    end if;
    v_bill_discount := round((v_subtotal - v_item_discounts) * coalesce(p_discount_percent, 0) / 100, 2);
  end if;
  v_discount := v_item_discounts + v_bill_discount;

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
  from (select format('%s|%s|%s|%s', i.variant_id, i.quantity, coalesce(i.customization::text, ''), round(coalesce(i.discount_amount, 0), 2)) as k
        from public.order_items i where i.order_id = o.id) old_items;
  select string_agg(k, ';' order by k) into v_new_key
  from (select format('%s|%s|%s|%s', x->>'variant_id', x->>'quantity',
                      case when jsonb_typeof(x->'flavors') = 'array' then (x->'flavors')::text else '' end,
                      round((x->>'discount')::numeric, 2)) as k
        from jsonb_array_elements(v_new_items) x) new_items;

  if coalesce(v_old_key, '') <> coalesce(v_new_key, '') then
    delete from public.order_items where order_items.order_id = o.id;
    for v_item in select value from jsonb_array_elements(v_new_items)
    loop
      insert into public.order_items (order_id, variant_id, product_name, variant_name, unit_price, quantity, total_price, customization, discount_amount, discount_label)
      select o.id, pv.id, p.name, pv.name, pv.price, (v_item->>'quantity')::integer,
             pv.price * (v_item->>'quantity')::integer,
             case when jsonb_typeof(v_item->'flavors') = 'array' then v_item->'flavors' end,
             (v_item->>'discount')::numeric, v_item->>'label'
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
    discount_reason = case when v_discount > 0 then coalesce(nullif(left(trim(coalesce(p_discount_reason, '')), 120), ''),
      case when v_bill_discount > 0 and p_discount_amount is not null then trim(to_char(p_discount_amount, 'FM999990.##')) || ' QAR off'
           when v_bill_discount > 0 then trim(to_char(p_discount_percent, 'FM990.##')) || '% off'
           else 'Item discounts' end) end,
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

revoke execute on function public.admin_update_order(uuid, text, text, text, text, text, text, text, date, text, jsonb, numeric, text, numeric, text, text, boolean, text, text, text, numeric) from public, anon;
grant execute on function public.admin_update_order(uuid, text, text, text, text, text, text, text, date, text, jsonb, numeric, text, numeric, text, text, boolean, text, text, text, numeric) to authenticated;

commit;
