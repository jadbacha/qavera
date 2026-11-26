-- QAVERA: new delivery prices, by distance from the shop.
--   0–15 km   QAR 15
--   15–25 km  QAR 20
--   25–35 km  QAR 25
--   35–50 km  QAR 30
--   over 50   QAR 40
-- Klavy free delivery ("inside Doha") stays on the same areas as before
-- (up to about 37 km, the old QAR 30 / 50 areas).
-- Paste into Supabase SQL Editor and click Run. Safe to run more than once.

begin;

-- 1. Remember which areas count as Doha, before the prices change.
alter table public.delivery_areas add column if not exists doha boolean;
update public.delivery_areas
   set doha = (fee > 0 and fee <= 50)
 where doha is null;

-- 2. Distances for the four areas added without one.
update public.delivery_areas set distance_km = 12 where distance_km is null and lower(name) in ('west bay', 'al rayyan');
update public.delivery_areas set distance_km = 21 where distance_km is null and lower(name) in ('the pearl', 'katara');

-- 3. New prices.
update public.delivery_areas set fee = case
    when distance_km <= 15 then 15
    when distance_km <= 25 then 20
    when distance_km <= 35 then 25
    when distance_km <= 50 then 30
    else 40
  end
 where distance_km is not null;

-- 4. Checkout: "inside Doha" now uses the area's Doha mark, not its price.
do $patch$
declare
  r record;
  v_def text;
  v_new text;
begin
  for r in select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname = 'create_qavera_order'
  loop
    v_def := pg_get_functiondef(r.oid);
    continue when position('Doha area (060)' in v_def) > 0;  -- already done
    v_new := regexp_replace(v_def,
      $r$v_area_fee\s*>\s*0\s+and\s+v_area_fee\s*<=\s*50$r$,
      $n$coalesce((select coalesce(a.doha, a.fee <= 25) /* Doha area (060) */
                 from public.delivery_areas a
                where a.active and lower(a.name) = lower(trim(p_delivery_area)) limit 1), false)$n$,
      'g');
    if v_new = v_def then
      raise exception 'Could not find the Doha check in create_qavera_order: send this message to Claude';
    end if;
    execute v_new;
  end loop;
end
$patch$;

commit;

-- Check 1: the new prices (15, 20, 25, 30, 40) and how many areas each.
select fee as delivery_charge, count(*) as areas, count(*) filter (where doha) as doha_areas
from public.delivery_areas where active group by fee order by fee;

-- Check 2: areas with no distance keep their old price. Change them on the admin page if any are listed.
select name, fee from public.delivery_areas where active and distance_km is null order by name;
