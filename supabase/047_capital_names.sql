-- QAVERA: customer names always start with capitals ("jad bacha" -> "Jad Bacha"),
-- whether the order comes from the website, the admin page or the till.
-- Also the recipient's name on gifts and the name on customer accounts.
-- Names already saved are fixed too.
-- Paste into Supabase SQL Editor and click Run. Safe to run more than once.

begin;

-- "jAD   bacha" -> "Jad Bacha", "al-thani" -> "Al-Thani". Arabic is left as it is.
create or replace function public.qavera_name_case(p_name text)
 returns text
 language sql
 immutable
as $function$
  select case
    when p_name is null then null
    when lower(trim(p_name)) = 'walk-in customer' then 'Walk-in customer'
    else initcap(regexp_replace(trim(p_name), '\s+', ' ', 'g'))
  end;
$function$;

create or replace function public.orders_name_case()
 returns trigger
 language plpgsql
as $function$
begin
  new.customer_name := public.qavera_name_case(new.customer_name);
  new.gift_recipient_name := public.qavera_name_case(new.gift_recipient_name);
  return new;
end;
$function$;

drop trigger if exists orders_name_case on public.orders;
create trigger orders_name_case
  before insert or update of customer_name, gift_recipient_name on public.orders
  for each row execute function public.orders_name_case();

create or replace function public.profiles_name_case()
 returns trigger
 language plpgsql
as $function$
begin
  new.full_name := public.qavera_name_case(new.full_name);
  return new;
end;
$function$;

drop trigger if exists profiles_name_case on public.profiles;
create trigger profiles_name_case
  before insert or update of full_name on public.profiles
  for each row execute function public.profiles_name_case();

-- Names already saved.
update public.orders
   set customer_name = public.qavera_name_case(customer_name),
       gift_recipient_name = public.qavera_name_case(gift_recipient_name)
 where customer_name is distinct from public.qavera_name_case(customer_name)
    or gift_recipient_name is distinct from public.qavera_name_case(gift_recipient_name);

update public.profiles
   set full_name = public.qavera_name_case(full_name)
 where full_name is distinct from public.qavera_name_case(full_name);

commit;
