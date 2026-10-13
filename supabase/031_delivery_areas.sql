-- QAVERA: delivery charge by area.
--   * QAR 30: 0–20 km · QAR 50: 21–37 km · QAR 70: 37 km and more (150 areas).
--   * New table delivery_areas (area name + delivery charge). Everyone can read
--     it (checkout shows the list); only admins can change it, from the admin
--     page → "Delivery areas".
--   * Website orders are charged the price of the chosen area. An area that is
--     not on the list is refused: the customer is asked to call or WhatsApp.
-- Paste into Supabase SQL Editor and click Run. Safe to run more than once.

begin;

create table if not exists public.delivery_areas (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  fee numeric not null check (fee >= 0),
  distance_km integer,
  active boolean not null default true,
  created_at timestamptz not null default now()
);
create unique index if not exists delivery_areas_name_key on public.delivery_areas (lower(name));

alter table public.delivery_areas enable row level security;

drop policy if exists "delivery areas are public" on public.delivery_areas;
create policy "delivery areas are public" on public.delivery_areas
  for select to anon, authenticated using (true);

drop policy if exists "admins manage delivery areas" on public.delivery_areas;
create policy "admins manage delivery areas" on public.delivery_areas
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

grant select on public.delivery_areas to anon, authenticated;
grant insert, update, delete on public.delivery_areas to authenticated;

-- The list (areas already there keep the price set on the admin page).
insert into public.delivery_areas (name, fee, distance_km)
select v.name, v.fee, v.km
from (values
  ('Fereej Al Nasr', 30, 2),
  ('Fereej Al Asiri', 30, 2),
  ('Fereej Al Soudan', 30, 2),
  ('New Al Mirqab', 30, 3),
  ('Fereej Bin Mahmoud', 30, 4),
  ('Rawdat Al Khail', 30, 4),
  ('Fereej Mohamed Bin Jasim', 30, 4),
  ('Al Jasrah', 30, 5),
  ('Fereej Abdel Aziz', 30, 5),
  ('As Salatah', 30, 5),
  ('Mushayrib', 30, 5),
  ('Wadi Al Sail', 30, 5),
  ('New Salatah', 30, 5),
  ('Fereej Al Asmakh', 30, 6),
  ('Al Najada', 30, 6),
  ('Al Mansoura', 30, 6),
  ('Barahat Al Jufairi', 30, 6),
  ('Ad Dawhah al Jadidah', 30, 6),
  ('Old Al Ghanim', 30, 7),
  ('Al Souq', 30, 7),
  ('Rumeilah', 30, 7),
  ('Fereej Bin Durham', 30, 7),
  ('Najma', 30, 7),
  ('Fereej Al Amir', 30, 7),
  ('Mehairja', 30, 7),
  ('Al Waab', 30, 8),
  ('Luaib', 30, 8),
  ('Zone 58', 30, 8),
  ('Fereej Al Murra', 30, 8),
  ('New Fereej Al Ghanim', 30, 8),
  ('Al Aziziya', 30, 8),
  ('New Fereej Al Khulaifat', 30, 8),
  ('Hamad Medical City', 30, 9),
  ('Fereej Bin Omran', 30, 9),
  ('Al Sadd', 30, 9),
  ('Al Messila', 30, 9),
  ('Fereej Kulaib', 30, 9),
  ('Umm Ghuwailina', 30, 9),
  ('Al Rufaa', 30, 9),
  ('Al Bidda', 30, 9),
  ('Al Mirqab', 30, 9),
  ('New Al Hitmi', 30, 9),
  ('Baaya', 30, 9),
  ('Lebday', 30, 9),
  ('Nuaija', 30, 9),
  ('Al Hilal', 30, 9),
  ('Al Mamoura', 30, 9),
  ('Abu Hamour', 30, 9),
  ('Ain Khaled', 30, 9),
  ('Muraikh', 30, 10),
  ('Doha Port', 30, 11),
  ('Al Khulaifat', 30, 11),
  ('Old Al Rayyan', 30, 11),
  ('Old Al Hitmi', 30, 11),
  ('Lejbailat', 30, 12),
  ('Al Dafna', 30, 12),
  ('Fereej Al Zaeem', 30, 12),
  ('Al Shagub', 30, 12),
  ('Old Airport', 30, 12),
  ('Onaiza', 30, 13),
  ('Madinat Khalifa South', 30, 13),
  ('Ras Abu Aboud', 30, 13),
  ('Al Luqta', 30, 13),
  ('New Al Rayyan', 30, 13),
  ('Hazm Al Markhiya', 30, 13),
  ('Industrial Area', 30, 14),
  ('Madinat Khalifa North', 30, 14),
  ('Al Thumama', 30, 14),
  ('Dahl Al Hamam', 30, 15),
  ('Doha International Airport', 30, 15),
  ('Mesaimeer', 30, 15),
  ('Bu Samra', 30, 15),
  ('Fereej Al Manaseer', 30, 15),
  ('Muaither', 30, 16),
  ('Gharrafat Al Rayyan', 30, 16),
  ('Duhail', 30, 17),
  ('Umm Lekhba', 30, 17),
  ('Al Markhiya', 30, 17),
  ('Al Gharrafa', 30, 17),
  ('Al Seej', 30, 17),
  ('Al Wajbah', 30, 17),
  ('Bu Sidra', 30, 17),
  ('Bani Hajer', 30, 17),
  ('Izghawa', 30, 17),
  ('Al Qassar', 30, 18),
  ('Jeryan Nejaima', 30, 18),
  ('Jelaiah', 30, 18),
  ('Zone 50', 30, 18),
  ('Rawdat Egdaim', 30, 18),
  ('Leabaib', 30, 19),
  ('Al Tarfa', 30, 19),
  ('Jeryan Jenaihat', 30, 19),
  ('Leqtaifiya', 50, 21),
  ('Jabal Thuaileb', 50, 21),
  ('Al Kharaitiyat', 50, 21),
  ('Al Mearad', 50, 22),
  ('Al Sailiya', 50, 22),
  ('Al Mashaf', 50, 22),
  ('Al Egla', 50, 22),
  ('Umm Salal Mohammed', 50, 22),
  ('Al Ebb', 50, 22),
  ('Al Kheesa', 50, 23),
  ('Wadi Al Banat', 50, 23),
  ('Al Wakrah', 50, 23),
  ('Al Themaid', 50, 24),
  ('Lusail', 50, 25),
  ('Mebaireek', 50, 27),
  ('Wadi Al Wasaah', 50, 27),
  ('Al Kharayej', 50, 28),
  ('Al Wukair', 50, 28),
  ('Al Sakhama', 50, 31),
  ('Rawdat Al Hamama', 50, 33),
  ('Umm Salal Ali', 50, 33),
  ('Umm Al Amad', 50, 33),
  ('Bu Fasseela', 50, 36),
  ('Umm Ebairiya', 50, 36),
  ('Wadi Lusail', 50, 37),
  ('Al Masrouhiya', 50, 37),
  ('Al Daayen', 70, 37),
  ('Umm Qarn', 70, 41),
  ('Rawdat Rashed', 70, 47),
  ('Mesaieed', 70, 47),
  ('Mesaieed Industrial Area', 70, 47),
  ('Saina Al-Humaidi', 70, 51),
  ('Simaisma', 70, 54),
  ('Al Jeryan', 70, 55),
  ('Al Khor City', 70, 55),
  ('Al-Shahaniya City', 70, 65),
  ('Al Karaana', 70, 70),
  ('Al Utouriya', 70, 70),
  ('Al Nasraniya', 70, 73),
  ('Al Kharrara', 70, 74),
  ('Al Thakhira', 70, 78),
  ('Umm Birka', 70, 80),
  ('Al Jemailiya', 70, 85),
  ('Shagra', 70, 85),
  ('Madinat Al Kaaban', 70, 90),
  ('Ras Laffan', 70, 90),
  ('Al Ghuwariyah', 70, 95),
  ('Abu Samra', 70, 100),
  ('Dukhan', 70, 102),
  ('Umm Bab', 70, 104),
  ('Sawda Natheel', 70, 110),
  ('Madinat ash Shamal', 70, 115),
  ('Ar Ru''ays', 70, 115),
  ('Khawr al Udayd', 70, 120),
  ('Fuwayrit', 70, 122),
  ('Ain Sinan', 70, 123),
  ('Zubarah', 70, 139),
  ('Abu Dhalouf', 70, 139)
) as v(name, fee, km)
where not exists (select 1 from public.delivery_areas a where lower(a.name) = lower(v.name));

-- Checkout: charge the price of the chosen area (changes only that part of the function).
do $$
declare
  v_def text := pg_get_functiondef('public.create_qavera_order(text, text, text, text, text, text, text, text, text, integer, boolean, text, jsonb, text, date, text, boolean, text, text, text)'::regprocedure);
  v_old text := E'  if v_pickup then\n    v_delivery := 0;  -- collected from the shop\n  end if;';
  v_new text := E'  if v_pickup then\n    v_delivery := 0;  -- collected from the shop\n  else\n    -- Delivery charge by area (admin page -> Delivery areas).\n    select a.fee into v_delivery from public.delivery_areas a\n     where a.active and lower(a.name) = lower(trim(p_delivery_area));\n    if not found then\n      raise exception ''We don''''t deliver to this area online yet. Please call or WhatsApp us on +974 5096 8968.'';\n    end if;\n  end if;';
begin
  if position('delivery_areas' in v_def) > 0 then
    raise notice 'Checkout already charges by area';
  elsif position(v_old in v_def) > 0 then
    execute replace(v_def, v_old, v_new);
    raise notice 'Checkout now charges by area';
  else
    raise exception 'Could not find the delivery charge in create_qavera_order';
  end if;
end $$;

commit;

-- Check: number of areas per price.
select fee as delivery_charge, count(*) as areas from public.delivery_areas where active group by fee order by fee;
