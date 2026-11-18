-- QAVERA: hide the offer codes. The website no longer reads the list of codes;
-- it only checks the one code the customer types (check_offer_code).
-- Admins and shop staff still see and manage them on the admin page.
-- Paste into Supabase SQL Editor and click Run. Safe to run more than once.

begin;

drop policy if exists "offer codes are public" on public.promo_codes;
drop policy if exists "staff read offer codes" on public.promo_codes;
create policy "staff read offer codes" on public.promo_codes
  for select using (public.is_admin() or public.is_store_staff());
revoke select on public.promo_codes from anon;

-- Checks one code. Returns nothing when the code doesn't exist or is switched off.
create or replace function public.check_offer_code(p_code text)
 returns table(code text, kind text, percent numeric, free_delivery_min numeric, min_subtotal numeric,
               needs_member boolean, member_label text, first_order_only boolean, description text)
 language sql
 stable
 security definer
 set search_path to 'public'
as $function$
  select c.code, c.kind, c.percent, c.free_delivery_min, c.min_subtotal,
         c.needs_member, c.member_label, c.first_order_only, c.description
    from public.promo_codes c
   where c.active and c.code = upper(trim(coalesce(p_code, '')))
     and char_length(coalesce(p_code, '')) <= 30;
$function$;
revoke execute on function public.check_offer_code(text) from public;
grant execute on function public.check_offer_code(text) to anon, authenticated;

commit;

-- Check: should return KLAVY10 only.
select code from public.check_offer_code('klavy10');
