-- QAVERA: the till's History can print a receipt for any order: adds the
-- full delivery address, the time slot and the gift details to the list
-- of orders (same as 046 otherwise).
-- Paste into Supabase SQL Editor and click Run. Safe to run more than once.

begin;

create or replace function public.list_all_orders(p_from timestamptz, p_to timestamptz)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
begin
  if not public.is_store_staff() then
    raise exception 'Only QAVERA staff can view orders';
  end if;

  return coalesce((
    select jsonb_agg(sale order by sale->>'sold_at' desc)
    from (
      select jsonb_build_object(
        'id', o.id,
        'order_number', o.order_number,
        'client_ref', o.client_ref,
        'sold_at', o.created_at,
        'source', o.source,
        'fulfillment_type', o.fulfillment_type,
        'scheduled_date', o.scheduled_date,
        'delivery_area', o.delivery_area,
        'delivery_address', o.delivery_address,
        'time_slot', o.time_slot,
        'gift_recipient_name', o.gift_recipient_name,
        'gift_recipient_phone', o.gift_recipient_phone,
        'delivery_fee', o.delivery_fee,
        'customer_name', o.customer_name,
        'customer_phone', o.customer_phone,
        'is_gift', o.is_gift,
        'subtotal', o.subtotal,
        'discount_amount', o.discount_amount,
        'points_discount', o.points_discount,
        'discount_reason', o.discount_reason,
        'total', o.total,
        'payment_method', o.payment_method,
        'payment_status', o.payment_status,
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
            'discount_amount', i.discount_amount,
            'discount_label', i.discount_label,
            'flavors', i.customization
          ) order by i.created_at)
          from public.order_items i where i.order_id = o.id
        ), '[]'::jsonb)
      ) as sale
      from public.orders o
      where o.created_at >= p_from
        and o.created_at < p_to
        and not (o.payment_method = 'card_online' and coalesce(o.payment_status, '') <> 'paid')
      order by o.created_at desc
      limit 3000
    ) s
  ), '[]'::jsonb);
end;
$$;

revoke execute on function public.list_all_orders(timestamptz, timestamptz) from public, anon;
grant execute on function public.list_all_orders(timestamptz, timestamptz) to authenticated;

commit;
