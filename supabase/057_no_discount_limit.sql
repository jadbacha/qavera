-- QAVERA: shop (till) discounts have no 15% limit any more.
-- A discount can be any amount, up to the whole sale.
-- Paste into Supabase SQL Editor and click Run. Safe to run more than once.

begin;

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
    continue when position('No discount limit (057)' in v_def) > 0;  -- already done
    -- The old limit: "if v_discount > round(v_subtotal * ...) then raise ... end if;"
    v_new := regexp_replace(v_def,
      $r$if\s+v_discount\s*>\s*round\s*\(\s*v_subtotal\s*\*[^;]*;\s*end\s+if\s*;$r$,
      $n$-- No discount limit (057): up to the whole sale.
  if v_discount > v_subtotal then
    raise exception 'The discount can''t be more than the sale (QAR %)', v_subtotal;
  end if;$n$);
    if v_new = v_def then
      raise exception 'Could not find the discount limit in create_store_sale: send this message to Claude';
    end if;
    execute v_new;
  end loop;
end
$patch$;

commit;

-- Check: should say "ok".
select case when pg_get_functiondef(p.oid) like '%(057)%' then 'ok' else 'NOT UPDATED' end as status
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'create_store_sale';
