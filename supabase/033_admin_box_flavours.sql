-- QAVERA: admin "New order" can add Premium / Luxury boxes with chosen flavours.
--   * Saves the flavours on the order line (like website orders) and checks
--     they add up to the box size (12, 25 or 48 pieces).
--   * Changes only that part of admin_create_order; everything else stays.
-- Paste into Supabase SQL Editor and click Run. Safe to run more than once.

do $$
declare
  v_sig regprocedure := 'public.admin_create_order(text, text, text, text, text, text, text, date, text, jsonb, numeric, text, numeric, text, text, boolean, text, text, text)'::regprocedure;
  v_def text := pg_get_functiondef(v_sig);
  v_decl_old text := E'  v_gift boolean := coalesce(p_gift, false);\nbegin';
  v_decl_new text := E'  v_gift boolean := coalesce(p_gift, false);\n  v_flavors jsonb;\n  v_pieces integer;\nbegin';
  v_qty_old text := E'    v_qty := (v_item->>''quantity'')::integer;\n    insert into public.order_items';
  v_qty_new text := E'    v_qty := (v_item->>''quantity'')::integer;\n'
    '    -- Chosen flavours for a box: keep name + quantity, and they must fill the box.\n'
    '    v_flavors := null;\n'
    '    if jsonb_typeof(v_item->''flavors'') = ''array'' then\n'
    '      select jsonb_agg(jsonb_build_object(''name'', left(trim(f->>''name''), 60), ''quantity'', (f->>''quantity'')::integer))\n'
    '        into v_flavors\n'
    '      from jsonb_array_elements(v_item->''flavors'') f\n'
    '      where coalesce(f->>''quantity'', '''') ~ ''^[0-9]{1,3}$'' and (f->>''quantity'')::integer > 0\n'
    '        and nullif(trim(f->>''name''), '''') is not null;\n'
    '      if v_flavors is not null then\n'
    '        select pv.pieces into v_pieces from public.product_variants pv where pv.id = (v_item->>''variant_id'')::uuid;\n'
    '        if v_pieces is null or (select sum((f->>''quantity'')::integer) from jsonb_array_elements(v_flavors) f) <> v_pieces then\n'
    '          raise exception ''The flavours must add up to % pieces'', coalesce(v_pieces, 0);\n'
    '        end if;\n'
    '      end if;\n'
    '    end if;\n'
    '    insert into public.order_items';
  v_ins_old text := E'pv.price * v_qty, null\n';
  v_ins_new text := E'pv.price * v_qty, v_flavors\n';
begin
  if position('v_flavors' in v_def) > 0 then
    raise notice 'New order already saves box flavours';
  elsif position(v_decl_old in v_def) > 0 and position(v_qty_old in v_def) > 0 and position(v_ins_old in v_def) > 0 then
    v_def := replace(v_def, v_decl_old, v_decl_new);
    v_def := replace(v_def, v_qty_old, v_qty_new);
    v_def := replace(v_def, v_ins_old, v_ins_new);
    execute v_def;
    raise notice 'New order now saves box flavours';
  else
    raise exception 'Could not find the parts to change in admin_create_order';
  end if;
end $$;
