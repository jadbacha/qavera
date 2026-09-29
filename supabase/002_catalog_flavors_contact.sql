-- QAVERA: products for Assorted/Bites/Slabs/Spreads/LâLI, LâLI flavours on orders,
-- and contact form messages.
-- Paste into Supabase SQL Editor and click Run. Safe to run more than once.
-- Run 001_security_and_points.sql first.

begin;

-- 1. Products that the Assorted, Bites, Slabs, Spreads and LâLI pages sell.
--    Names and prices match the website. Products whose name already exists are skipped.

alter table public.product_variants
  add column if not exists pieces integer;  -- box size, used to check custom flavour counts

create temp table qavera_new_products (
  name text, slug text, category text, variant_name text, price numeric, pieces integer
) on commit drop;

insert into qavera_new_products values
  ('Hazelnut Mandiant',                         'hazelnut-mandiant',                         'assorted', '500 G',                 190, null),
  ('Almond Mandiant',                           'almond-mandiant',                           'assorted', '500 G',                 190, null),
  ('Crispy Feuilletine',                        'crispy-feuilletine',                        'assorted', '500 G',                 190, null),
  ('Chocolate Gianduja Crispy Rice',            'chocolate-gianduja-crispy-rice',            'assorted', '500 G',                 190, null),
  ('Speculoos with Chocolate Ganache',          'specullos-with-chocolate-ganache',          'assorted', '500 G',                 190, null),
  ('Mix Assorted',                              'mix-assorted',                              'assorted', '500 G',                 190, null),
  ('Almond Florentine with Chocolate',          'almond-florentine-with-chocolate',          'bites',    '50 G',                   25, null),
  ('Pretzels with Chocolate',                   'pretzels-with-chocolate',                   'bites',    '50 G',                   25, null),
  ('Pringles with Chocolate',                   'pringles-with-chocolate',                   'bites',    '50 G',                   25, null),
  ('White Chocolate with Almond and Raspberry', 'white-chocolate-with-almond-and-raspberry', 'slabs',    '100 G',                  50, null),
  ('Dark Chocolate with Hazelnuts and Cashew',  'dark-chocolate-with-hazelnuts-and-cashew',  'slabs',    '100 G',                  50, null),
  ('Milk Chocolate with Mix Nuts',              'milk-chocolate-with-mix-nuts',              'slabs',    '100 G',                  50, null),
  ('Hazelnut Spread',                           'hazelnut-spread',                           'spreads',  '280ml',                  60, null),
  ('Pistachio Spread',                          'pistachio-spread',                          'spreads',  '280ml',                  60, null),
  ('Lotus Spread',                              'lotus-spread',                              'spreads',  '280ml',                  60, null),
  ('LâLI Box',                                  'lali-box',                                  'lali',     '12 Pieces — Burgundy',   10, 12),
  ('LâLI Box',                                  'lali-box',                                  'lali',     '25 Pieces — Green',      20, 25),
  ('LâLI Box',                                  'lali-box',                                  'lali',     '48 Pieces — Black',      30, 48);

insert into public.products (name, slug, category, active)
select distinct n.name, n.slug, n.category, true
from qavera_new_products n
where not exists (select 1 from public.products p where lower(p.name) = lower(n.name));

insert into public.product_variants (product_id, name, price, pieces, active)
select p.id, n.variant_name, n.price, n.pieces, true
from qavera_new_products n
join public.products p on lower(p.name) = lower(n.name)
where not exists (
  select 1 from public.product_variants v
  where v.product_id = p.id and lower(v.name) = lower(n.variant_name)
);

update public.product_variants v
set pieces = n.pieces
from qavera_new_products n
join public.products p on lower(p.name) = lower(n.name)
where v.product_id = p.id and lower(v.name) = lower(n.variant_name)
  and n.pieces is not null and v.pieces is distinct from n.pieces;


-- 2. Store LâLI custom flavours on each order line.

alter table public.order_items
  add column if not exists customization jsonb;

-- Same as the current create_qavera_order, plus: each cart item may carry
-- "flavors": [{"name": "...", "quantity": n}, ...]. It is checked (the counts
-- must add up to the box size) and saved in order_items.customization.
create or replace function public.create_qavera_order(p_customer_name text, p_customer_phone text, p_customer_email text, p_delivery_address text, p_delivery_area text, p_building text, p_apartment text, p_notes text, p_payment_method text, p_points_used integer, p_save_address boolean, p_address_label text, p_items jsonb)
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

  v_total := v_subtotal - v_discount + v_delivery;

  insert into public.orders (
    user_id, source, fulfillment_type, customer_name, customer_phone, customer_email,
    delivery_address, delivery_area, subtotal, delivery_fee, total, status, notes,
    payment_method, payment_status, points_used, points_discount
  )
  values (
    v_user_id,
    'website',
    'delivery',
    trim(p_customer_name),
    trim(p_customer_phone),
    nullif(trim(p_customer_email), ''),
    trim(p_delivery_address) || E'\nBuilding / Villa: ' || trim(p_building) || E'\nApartment / Floor: ' || trim(p_apartment),
    trim(p_delivery_area),
    v_subtotal,
    v_delivery,
    v_total,
    'pending',
    nullif(trim(p_notes), ''),
    p_payment_method,
    'pending',
    v_points,
    v_discount
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

  if p_save_address then
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


-- 3. Contact form messages. Anyone can send one; nobody can read them through the
--    website (you read them in Table Editor → contact_messages).

create table if not exists public.contact_messages (
  id uuid primary key default gen_random_uuid(),
  user_id uuid default auth.uid() references auth.users(id) on delete set null,
  name text not null check (char_length(trim(name)) between 1 and 100),
  email text not null check (char_length(email) <= 200 and email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'),
  phone text check (phone is null or char_length(phone) <= 30),
  reason text not null check (reason in ('general', 'support', 'corporate')),
  message text not null check (char_length(trim(message)) between 1 and 5000),
  status text not null default 'new',
  created_at timestamptz not null default now()
);

alter table public.contact_messages enable row level security;

revoke all on public.contact_messages from anon, authenticated;
grant insert (name, email, phone, reason, message) on public.contact_messages to anon, authenticated;

drop policy if exists "Anyone can send a contact message" on public.contact_messages;
create policy "Anyone can send a contact message"
  on public.contact_messages for insert
  to anon, authenticated
  with check (user_id is null or user_id = auth.uid());

-- Basic spam limit: at most 5 messages per email address per hour.
create or replace function public.limit_contact_messages()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if (
    select count(*) from public.contact_messages
    where lower(email) = lower(new.email)
      and created_at > now() - interval '1 hour'
  ) >= 5 then
    raise exception 'Too many messages. Please try again later.';
  end if;
  return new;
end;
$$;

revoke execute on function public.limit_contact_messages() from public, anon, authenticated;

drop trigger if exists limit_contact_messages on public.contact_messages;
create trigger limit_contact_messages
  before insert on public.contact_messages
  for each row execute function public.limit_contact_messages();

commit;
