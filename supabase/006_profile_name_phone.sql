-- QAVERA: fill in the name and phone on new profiles from sign-up details.
-- Email sign-up sends first_name / last_name / phone (not full_name), so until
-- now those profiles were saved with an empty name and no phone. This fixes new
-- sign-ups and fills in existing profiles that are missing them.
-- Paste into Supabase SQL Editor and click Run. Safe to run more than once.

begin;

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  meta jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
  v_name text;
  v_phone text;
begin
  v_name := coalesce(
    nullif(trim(meta ->> 'full_name'), ''),
    nullif(trim(concat_ws(' ', meta ->> 'first_name', meta ->> 'last_name')), ''),
    nullif(trim(meta ->> 'name'), ''),
    ''
  );

  -- Stored as +<country code><digits>, e.g. +97455555555
  v_phone := nullif(regexp_replace(
    coalesce(meta ->> 'phone_full', concat(meta ->> 'phone_country_code', meta ->> 'phone')), '[^0-9+]', '', 'g'), '');

  insert into public.profiles (id, full_name, email, phone)
  values (new.id, v_name, new.email, v_phone);

  return new;
end;
$$;

-- Fill in existing profiles that are missing a name or phone.
update public.profiles p
set full_name = coalesce(
      nullif(trim(u.raw_user_meta_data ->> 'full_name'), ''),
      nullif(trim(concat_ws(' ', u.raw_user_meta_data ->> 'first_name', u.raw_user_meta_data ->> 'last_name')), ''),
      nullif(trim(u.raw_user_meta_data ->> 'name'), ''),
      p.full_name)
from auth.users u
where u.id = p.id
  and coalesce(trim(p.full_name), '') = '';

update public.profiles p
set phone = nullif(regexp_replace(
      coalesce(u.raw_user_meta_data ->> 'phone_full',
               concat(u.raw_user_meta_data ->> 'phone_country_code', u.raw_user_meta_data ->> 'phone')),
      '[^0-9+]', '', 'g'), '')
from auth.users u
where u.id = p.id
  and coalesce(trim(p.phone), '') = '';

commit;
