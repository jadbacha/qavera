-- QAVERA: customized boxes in the shop till (POS).
-- Paste into Supabase SQL Editor and click Run. Safe to run more than once.
-- Run 008_store_pos.sql first.
--
-- A shop sale line may now carry the flavours chosen for a Premium / Luxury box,
-- checked the same way as on the website (they must add up to the box size) and
-- saved in order_items.customization, so they show on the admin page.

begin;

-- 1. Save one shop sale. Prices always come from the database.
--    p_items: [{"variant_id": "...", "quantity": 2, "flavors": [{"name": "...", "quantity": 6}] }, ...]
--    "flavors" is only for customized Premium / Luxury boxes.
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
  v_flavors jsonb;
  v_flavor jsonb;
  v_flavor_total integer;
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

    select pv.price, pv.pieces into v_variant
    from public.product_variants pv
    where pv.id = (v_item->>'variant_id')::uuid;

    if not found then
      raise exception 'Unknown product';
    end if;

    -- Customized box: the flavour counts must add up to the box size.
    v_flavors := v_item->'flavors';
    if v_flavors is not null and jsonb_typeof(v_flavors) <> 'null' then
      if v_variant.pieces is null then
        raise exception 'This product cannot be customized';
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
        v_flavor_total := v_flavor_total + (v_flavor->>'quantity')::integer;
      end loop;

      if v_flavor_total <> v_variant.pieces then
        raise exception 'A customized box must contain exactly % pieces', v_variant.pieces;
      end if;
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

    insert into public.order_items (order_id, variant_id, product_name, variant_name, unit_price, quantity, total_price, customization)
    select v_order_id, pv.id, p.name, pv.name, pv.price, v_qty, pv.price * v_qty, v_flavors
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

-- 2. Shop sales between two times, with their items (for the POS history).
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
            'total_price', i.total_price,
            'flavors', i.customization
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

-- Check: should list both functions.
select proname from pg_proc where proname in ('create_store_sale', 'list_store_sales');
