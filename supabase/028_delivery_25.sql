-- QAVERA: delivery charge QAR 25 (was QAR 20). Pickup stays free.
-- Changes only the delivery charge inside the current checkout function;
-- everything else stays as it is. Orders already placed keep their charge.
-- Paste into Supabase SQL Editor and click Run. Safe to run more than once.

do $$
declare
  v_def text := pg_get_functiondef('public.create_qavera_order(text, text, text, text, text, text, text, text, text, integer, boolean, text, jsonb, text, date, text)'::regprocedure);
begin
  if position('v_delivery numeric := 25;' in v_def) > 0 then
    raise notice 'Delivery charge is already QAR 25';
  elsif position('v_delivery numeric := 20;' in v_def) > 0 then
    execute replace(v_def, 'v_delivery numeric := 20;', 'v_delivery numeric := 25;');
    raise notice 'Delivery charge changed to QAR 25';
  else
    raise exception 'Could not find the delivery charge in create_qavera_order';
  end if;
end $$;

-- Check: should say 25.
select substring(pg_get_functiondef('public.create_qavera_order'::regproc) from 'v_delivery numeric := ([0-9]+);') as delivery_charge;
