-- QAVERA: offer codes for partners (JETOUR Club and Klavy).
--   JETOUR10      10% off the whole bill + free delivery in Doha on orders of QAR 220+
--                 (counted before the discount). Needs the JETOUR Club membership number.
--   JETOURFRIEND  10% off a first order, for friends referred by a JETOUR Club member.
--                 Needs the referring member's number. Once per customer.
--   KLAVY10       10% off the whole bill.
--   KLAVYHOTEL    Free delivery to a hotel in Doha (areas charged QAR 30 / 50).
--   KLAVYBITES    A free Bites (100 G) of the customer's choice on orders of QAR 220+.
-- One code per order, never together with QAVERA points.
-- "Doha" = delivery areas charged QAR 50 or less (QAR 70 areas are outside Doha).
-- The discount is saved like shop discounts (discount_amount + discount_reason),
-- so receipts, reports and editing an order keep working.
-- Paste into Supabase SQL Editor and click Run. Safe to run more than once.

begin;

-- 1. The codes. Admins switch them on/off on the admin page (Offers).
create table if not exists public.promo_codes (
  code text primary key check (code = upper(code)),
  partner text not null,
  kind text not null check (kind in ('percent', 'hotel', 'bites')),
  percent numeric not null default 0,
  free_delivery_min numeric,
  min_subtotal numeric,
  needs_member boolean not null default false,
  member_label text,
  first_order_only boolean not null default false,
  description text,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

alter table public.promo_codes enable row level security;
drop policy if exists "offer codes are public" on public.promo_codes;
create policy "offer codes are public" on public.promo_codes
  for select using (active or public.is_admin());
drop policy if exists "admins manage offer codes" on public.promo_codes;
create policy "admins manage offer codes" on public.promo_codes
  for update using (public.is_admin()) with check (public.is_admin());
grant select on public.promo_codes to anon, authenticated;
grant update on public.promo_codes to authenticated;

insert into public.promo_codes (code, partner, kind, percent, free_delivery_min, min_subtotal, needs_member, member_label, first_order_only, description) values
  ('JETOUR10',     'JETOUR', 'percent', 10, 220,  null, true,  'JETOUR Club membership number', false, '10% off your total bill, plus free delivery in Doha on orders of QAR 220+'),
  ('JETOURFRIEND', 'JETOUR', 'percent', 10, null, null, true,  'membership number of the JETOUR Club member who referred you', true, '10% off your first order, for friends of JETOUR Club members'),
  ('KLAVY10',      'Klavy',  'percent', 10, null, null, false, null, false, '10% off your total bill'),
  ('KLAVYHOTEL',   'Klavy',  'hotel',    0, null, null, false, null, false, 'Free delivery to your hotel in Doha'),
  ('KLAVYBITES',   'Klavy',  'bites',    0, null, 220,  false, null, false, 'A free Bites (100 G) of your choice on orders of QAR 220+')
on conflict (code) do nothing;

-- 2. What each order used.
alter table public.orders
  add column if not exists promo_code text,
  add column if not exists promo_member text,
  add column if not exists delivery_waived numeric not null default 0,
  add column if not exists is_hotel boolean not null default false;
create index if not exists orders_promo_code_idx on public.orders (promo_code) where promo_code is not null;

-- 3. Shop sales (till) and admin orders: a discount whose reason starts with a
--    code ("KLAVY10 · 10% off", "JETOUR10 · 10% off · Member 12345") is
--    recorded as that offer.
create or replace function public.orders_promo_from_reason()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_code text;
begin
  if new.promo_code is null and nullif(trim(coalesce(new.discount_reason, '')), '') is not null then
    v_code := upper(split_part(trim(new.discount_reason), ' ', 1));
    if exists (select 1 from public.promo_codes c where c.code = v_code) then
      new.promo_code := v_code;
      new.promo_member := nullif(substring(new.discount_reason from 'Member\s+([^\s·]+)'), '');
    end if;
  end if;
  return new;
end;
$function$;

drop trigger if exists orders_promo_from_reason on public.orders;
create trigger orders_promo_from_reason
  before insert or update of discount_reason on public.orders
  for each row execute function public.orders_promo_from_reason();

-- 4. Till: the free Bites can be more than the usual 15% shop discount.
--    Up to 25% when the discount reason starts with an offer code.
do $patch$
declare
  r record;
  v_def text;
  v_new text;
begin
  for r in select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname = 'create_store_sale'
  loop
    v_def := pg_get_functiondef(r.oid);
    if position('0.15 end' in v_def) > 0 then
      continue;  -- already patched
    end if;
    v_new := replace(v_def,
      'if v_discount > round(v_subtotal * 0.15, 2) then',
      'if v_discount > round(v_subtotal * case when exists (select 1 from public.promo_codes pc where pc.active and pc.code = upper(split_part(trim(coalesce(p_discount_reason, '''')), '' '', 1))) then 0.25 else 0.15 end, 2) then');
    if v_new = v_def then
      raise exception 'Could not find the shop discount limit in create_store_sale';
    end if;
    execute v_new;
  end loop;
end
$patch$;

-- 5. Admin page: record the offer used on an order made or edited there.
create or replace function public.admin_set_order_promo(p_order_id uuid, p_code text, p_member text default null, p_delivery_waived numeric default 0)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_code text := nullif(upper(trim(coalesce(p_code, ''))), '');
begin
  if not public.is_store_staff() then
    raise exception 'Only QAVERA staff can change orders';
  end if;
  if v_code is not null and not exists (select 1 from public.promo_codes c where c.code = v_code) then
    raise exception 'Unknown offer code %', v_code;
  end if;
  update public.orders set
    promo_code = v_code,
    promo_member = case when v_code is null then null else nullif(left(trim(coalesce(p_member, '')), 40), '') end,
    delivery_waived = case when v_code is null then 0 else greatest(coalesce(p_delivery_waived, 0), 0) end
  where id = p_order_id;
end;
$function$;
revoke execute on function public.admin_set_order_promo(uuid, text, text, numeric) from public, anon;
grant execute on function public.admin_set_order_promo(uuid, text, text, numeric) to authenticated;

-- 6. Website checkout with offer codes and hotel delivery.
drop function if exists public.create_qavera_order(text, text, text, text, text, text, text, text, text, integer, boolean, text, jsonb, text, date, text, boolean, text, text, text);

CREATE OR REPLACE FUNCTION public.create_qavera_order(p_customer_name text, p_customer_phone text, p_customer_email text, p_delivery_address text, p_delivery_area text, p_building text, p_apartment text, p_notes text, p_payment_method text, p_points_used integer, p_save_address boolean, p_address_label text, p_items jsonb, p_fulfillment text DEFAULT 'delivery'::text, p_scheduled_date date DEFAULT NULL::date, p_time_slot text DEFAULT NULL::text, p_gift boolean DEFAULT false, p_gift_name text DEFAULT NULL::text, p_gift_phone text DEFAULT NULL::text, p_gift_message text DEFAULT NULL::text, p_promo_code text DEFAULT NULL::text, p_promo_member text DEFAULT NULL::text, p_hotel boolean DEFAULT false, p_hotel_name text DEFAULT NULL::text, p_hotel_room text DEFAULT NULL::text, p_free_bites_variant uuid DEFAULT NULL::uuid)
 RETURNS TABLE(order_id uuid, order_number text, subtotal numeric, delivery_fee numeric, points_discount numeric, total numeric, points_used integer, promo_discount numeric)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  -- Offer codes (054_offers.sql)
  v_hotel boolean := coalesce(p_hotel, false) and lower(coalesce(p_fulfillment, 'delivery')) <> 'pickup';
  v_promo_code text := nullif(upper(trim(coalesce(p_promo_code, ''))), '');
  v_member text := nullif(trim(coalesce(p_promo_member, '')), '');
  v_code record;
  v_bites record;
  v_area_fee numeric := 0;
  v_waived numeric := 0;
  v_promo_discount numeric := 0;
  v_reason text;
  v_saved_code text;
  v_saved_member text;
  v_free_bites boolean := false;
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

    if v_hotel then
      if nullif(trim(p_hotel_name), '') is null then
        raise exception 'Please enter the hotel name';
      end if;
      if nullif(trim(p_hotel_room), '') is null then
        raise exception 'Please enter the room number';
      end if;
      if char_length(p_hotel_name) > 120 or char_length(p_hotel_room) > 40 then
        raise exception 'The hotel name or room number is too long';
      end if;
    else
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
  end if;

  if p_payment_method not in ('cash_on_delivery', 'card_on_delivery', 'fawran', 'card_online') then
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
    if p_payment_method not in ('fawran', 'card_online') then
      raise exception 'Gifts are paid in advance, by Fawran or by card online';
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

    if lower(trim(v_variant.product_name)) in ('premium', 'luxury', 'chocolate bonbons') then
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
  else
    -- Delivery charge by area (admin page -> Delivery areas).
    select a.fee into v_delivery from public.delivery_areas a
     where a.active and lower(a.name) = lower(trim(p_delivery_area));
    if not found then
      raise exception 'We don''t deliver to this area online yet. Please call or WhatsApp us on +974 5096 8968.';
    end if;
  end if;

  -- Offer code: one per order, never together with points.
  v_area_fee := v_delivery;
  if v_promo_code is not null then
    select * into v_code from public.promo_codes c where c.code = v_promo_code and c.active;
    if not found then
      raise exception 'This offer code isn''t valid.';
    end if;
    if v_points > 0 then
      raise exception 'Offer codes can''t be combined with QAVERA points. Please use one or the other.';
    end if;
    if v_code.needs_member then
      if v_member is null then
        raise exception 'Please enter the %.', coalesce(v_code.member_label, 'membership number');
      end if;
      if char_length(v_member) > 40 then
        raise exception 'The membership number is too long.';
      end if;
    end if;
    if v_code.first_order_only and exists (
      select 1 from public.orders o
       where o.status <> 'cancelled'
         and (o.user_id = v_user_id
              or right(regexp_replace(coalesce(o.customer_phone, ''), '\D', '', 'g'), 8)
               = right(regexp_replace(coalesce(p_customer_phone, ''), '\D', '', 'g'), 8))
    ) then
      raise exception '% is for your first order only.', v_code.code;
    end if;

    if v_code.kind = 'hotel' then
      if v_pickup or not v_hotel then
        raise exception '% is for delivery to a hotel. Please choose delivery and tick "Delivering to a hotel".', v_code.code;
      end if;
      if not (v_area_fee > 0 and v_area_fee <= 50) then
        raise exception 'Free hotel delivery is for hotels inside Doha.';
      end if;
      v_waived := v_area_fee;
      v_delivery := 0;
      v_reason := v_code.code || ' · Free hotel delivery';
    elsif v_code.kind = 'bites' then
      if v_subtotal < coalesce(v_code.min_subtotal, 0) then
        raise exception 'The free Bites is for orders of QAR % or more (not counting delivery).', v_code.min_subtotal;
      end if;
      select pv.id, pv.name, pv.price, p.name as product_name into v_bites
        from public.product_variants pv
        join public.products p on p.id = pv.product_id
       where pv.id = p_free_bites_variant and pv.active and p.active
         and lower(coalesce(p.category, '')) = 'bites'
         and coalesce(p.in_stock, true);
      if not found then
        raise exception 'Please choose your free Bites.';
      end if;
      v_subtotal := v_subtotal + v_bites.price;  -- listed on the order, fully discounted
      v_promo_discount := v_bites.price;
      v_free_bites := true;
      v_reason := v_code.code || ' · Free Bites';
    else
      if v_code.free_delivery_min is not null and not v_pickup
         and v_subtotal >= v_code.free_delivery_min
         and v_area_fee > 0 and v_area_fee <= 50 then
        v_waived := v_area_fee;
        v_delivery := 0;
      end if;
      v_promo_discount := round((v_subtotal + v_delivery) * v_code.percent / 100, 2);
      v_reason := v_code.code || ' · ' || trim(to_char(v_code.percent, 'FM990.##')) || '% off';
    end if;
    if v_code.needs_member then
      v_reason := v_reason || ' · Member ' || v_member;
      v_saved_member := v_member;
    end if;
    v_saved_code := v_code.code;
  end if;

  v_total := v_subtotal - v_discount - v_promo_discount + v_delivery;

  insert into public.orders (
    user_id, source, fulfillment_type, customer_name, customer_phone, customer_email,
    delivery_address, delivery_area, subtotal, delivery_fee, total, status, notes,
    payment_method, payment_status, points_used, points_discount,
    scheduled_date, time_slot,
    is_gift, gift_recipient_name, gift_recipient_phone, gift_message,
    discount_amount, discount_reason, promo_code, promo_member, delivery_waived, is_hotel
  )
  values (
    v_user_id,
    'website',
    case when v_pickup then 'pickup' else 'delivery' end,
    trim(p_customer_name),
    trim(p_customer_phone),
    nullif(trim(p_customer_email), ''),
    case when v_pickup then 'Pickup from the QAVERA shop'
         when v_hotel then 'Hotel: ' || trim(p_hotel_name) || E'\nRoom: ' || trim(p_hotel_room)
              || coalesce(E'\n' || nullif(trim(p_delivery_address), ''), '')
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
    case when v_gift then nullif(trim(p_gift_message), '') end,
    v_promo_discount,
    v_reason,
    v_saved_code,
    v_saved_member,
    v_waived,
    v_hotel
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

  if v_free_bites then
    insert into public.order_items (
      order_id, variant_id, product_name, variant_name, unit_price, quantity, total_price,
      customization, discount_amount, discount_label
    )
    values (
      v_order_id, v_bites.id, v_bites.product_name, v_bites.name, v_bites.price, 1, v_bites.price,
      null, v_bites.price, '100% off · Free Bites (' || v_saved_code || ')'
    );
  end if;

  if v_points > 0 then
    update public.profiles
    set points = points - v_points
    where id = v_user_id;
  end if;

  if p_save_address and not v_pickup and not v_gift and not v_hotel then
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

  return query select v_order_id, v_order_number, v_subtotal, v_delivery, v_discount, v_total, v_points, v_promo_discount;
end;
$function$

;

revoke execute on function public.create_qavera_order(text, text, text, text, text, text, text, text, text, integer, boolean, text, jsonb, text, date, text, boolean, text, text, text, text, text, boolean, text, text, uuid) from public, anon;
grant execute on function public.create_qavera_order(text, text, text, text, text, text, text, text, text, integer, boolean, text, jsonb, text, date, text, boolean, text, text, text, text, text, boolean, text, text, uuid) to authenticated;

commit;

-- Check: the five codes.
select code, partner, kind, percent, free_delivery_min, min_subtotal, needs_member, first_order_only, active
from public.promo_codes order by partner, code;
