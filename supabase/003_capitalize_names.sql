-- QAVERA: always store customer names with capital first letters ("jad bacha" -> "Jad Bacha").
-- Covers every way a name gets in: email sign-up, Google sign-in, and the account page.
-- Paste into Supabase SQL Editor and click Run. Safe to run more than once.

begin;

create or replace function public.capitalize_profile_name()
returns trigger
language plpgsql
set search_path to 'public'
as $$
begin
  if new.full_name is not null then
    new.full_name := initcap(lower(regexp_replace(trim(new.full_name), '\s+', ' ', 'g')));
  end if;
  return new;
end;
$$;

drop trigger if exists capitalize_profile_name on public.profiles;
create trigger capitalize_profile_name
  before insert or update of full_name on public.profiles
  for each row execute function public.capitalize_profile_name();

-- Fix names that are already saved.
update public.profiles
set full_name = full_name
where full_name is not null
  and full_name <> initcap(lower(regexp_replace(trim(full_name), '\s+', ' ', 'g')));

commit;
