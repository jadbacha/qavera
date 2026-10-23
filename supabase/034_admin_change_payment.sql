-- QAVERA: admins can change how an order is paid (e.g. cash → Fawran) and
-- whether it is already paid, from the admin page ("Change payment").
-- Paste into Supabase SQL Editor and click Run. Safe to run more than once.

create or replace function public.admin_set_payment_method(p_order_id uuid, p_method text, p_paid boolean)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
begin
  if not coalesce(public.is_admin(), false) then
    raise exception 'Only QAVERA admins can change payments';
  end if;
  if p_method not in ('cash_on_delivery', 'card_on_delivery', 'fawran') then
    raise exception 'Invalid payment method';
  end if;
  update public.orders
     set payment_method = p_method,
         payment_status = case when p_paid then 'paid' else 'pending' end
   where id = p_order_id and source <> 'store';
  if not found then
    raise exception 'Order not found';
  end if;
end;
$function$;

revoke execute on function public.admin_set_payment_method(uuid, text, boolean) from public, anon;
grant execute on function public.admin_set_payment_method(uuid, text, boolean) to authenticated;
