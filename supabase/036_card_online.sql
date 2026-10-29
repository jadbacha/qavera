-- QAVERA: pay online by card (Noqoody) at checkout.
--   * New payment method 'card_online': the customer pays on the Noqoody
--     page right after placing the order (gifts can use it too).
--   * The order keeps the Noqoody payment references, so the server can
--     confirm the payment and mark the order paid.
--   * Admins can keep 'card_online' when editing or changing a payment.
-- Paste into Supabase SQL Editor and click Run. Safe to run more than once.

begin;

alter table public.orders
  add column if not exists online_payment_refs text[] not null default '{}',
  add column if not exists online_paid_at timestamptz;

alter table public.orders drop constraint if exists orders_payment_method_check;
alter table public.orders add constraint orders_payment_method_check
  check (payment_method in ('cash_on_delivery', 'card_on_delivery', 'fawran', 'card_online') or source = 'store');

-- Allow 'card_online' in the checkout, the admin edit and "Change payment".
do $patch$
declare
  v_fn text;
  v_def text;
  v_new text;
begin
  foreach v_fn in array array[
    'public.create_qavera_order(text, text, text, text, text, text, text, text, text, integer, boolean, text, jsonb, text, date, text, boolean, text, text, text)',
    'public.admin_update_order(uuid, text, text, text, text, text, text, text, date, text, jsonb, numeric, text, numeric, text, text, boolean, text, text, text)',
    'public.admin_set_payment_method(uuid, text, boolean)'
  ]
  loop
    v_def := pg_get_functiondef(v_fn::regprocedure);
    if position('''fawran'', ''card_online'')' in v_def) > 0 then
      continue;  -- already done
    end if;
    v_new := replace(v_def,
      'not in (''cash_on_delivery'', ''card_on_delivery'', ''fawran'')',
      'not in (''cash_on_delivery'', ''card_on_delivery'', ''fawran'', ''card_online'')');
    if v_new = v_def then
      raise exception 'Could not find the payment methods in %', v_fn;
    end if;
    -- Gifts are paid in advance: by Fawran or by card online.
    v_new := replace(v_new,
      'if p_payment_method <> ''fawran'' then
      raise exception ''Gifts are paid in advance by Fawran'';',
      'if p_payment_method not in (''fawran'', ''card_online'') then
      raise exception ''Gifts are paid in advance, by Fawran or by card online'';');
    execute v_new;
  end loop;
end
$patch$;

commit;
