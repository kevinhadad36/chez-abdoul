-- Gestionnaires du magasin (comptes Supabase Auth autorisés à gérer)
create table public.admins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.admins enable row level security;

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.admins where user_id = auth.uid());
$$;

create policy "admins voient la liste" on public.admins for select using (public.is_admin());

-- Produits
create table public.products (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 80),
  category text not null default 'Fruits' check (char_length(category) between 1 and 40),
  unit text not null default 'kg' check (char_length(unit) between 1 and 30),
  price numeric(8,2) not null check (price >= 0 and price < 10000),
  image_url text,
  available boolean not null default true,
  sort int not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.products enable row level security;

create policy "catalogue public" on public.products for select using (available or public.is_admin());
create policy "admins ajoutent" on public.products for insert with check (public.is_admin());
create policy "admins modifient" on public.products for update using (public.is_admin()) with check (public.is_admin());
create policy "admins suppriment" on public.products for delete using (public.is_admin());

-- Commandes click & collect
create table public.orders (
  id uuid primary key default gen_random_uuid(),
  reference text not null unique,
  customer_name text not null check (char_length(customer_name) between 1 and 60),
  phone text not null check (char_length(phone) between 6 and 20),
  pickup_date date not null,
  pickup_time text not null check (pickup_time ~ '^[0-2][0-9]h[0-5][0-9]$'),
  note text check (note is null or char_length(note) <= 300),
  items jsonb not null,
  total numeric(10,2) not null,
  status text not null default 'nouvelle' check (status in ('nouvelle','en préparation','prête','retirée','annulée')),
  fulfillment text not null default 'retrait' check (fulfillment in ('retrait','livraison')),
  created_at timestamptz not null default now()
);
alter table public.orders enable row level security;

create policy "admins voient les commandes" on public.orders for select using (public.is_admin());
create policy "admins changent le statut" on public.orders for update using (public.is_admin()) with check (public.is_admin());

create index orders_pickup_idx on public.orders (pickup_date, pickup_time);

-- Passage de commande : les prix sont recalculés côté serveur, jamais pris du navigateur
create or replace function public.place_order(
  p_name text, p_phone text, p_pickup_date date, p_pickup_time text, p_note text, p_items jsonb
) returns text
language plpgsql security definer set search_path = public as $$
declare
  v_items jsonb := '[]'::jsonb;
  v_total numeric(10,2) := 0;
  v_ref text;
  r record;
begin
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 or jsonb_array_length(p_items) > 60 then
    raise exception 'Panier vide ou invalide';
  end if;
  if p_pickup_date < (now() at time zone 'Europe/Paris')::date
     or p_pickup_date > (now() at time zone 'Europe/Paris')::date + 14 then
    raise exception 'Date de retrait invalide';
  end if;

  for r in
    select p.id, p.name, p.unit, p.price, least(greatest((i->>'qty')::int, 1), 50) as qty
    from jsonb_array_elements(p_items) i
    join public.products p on p.id = (i->>'id')::uuid and p.available
  loop
    v_items := v_items || jsonb_build_object('id', r.id, 'name', r.name, 'unit', r.unit, 'price', r.price, 'qty', r.qty);
    v_total := v_total + r.price * r.qty;
  end loop;

  if jsonb_array_length(v_items) = 0 then
    raise exception 'Aucun produit disponible dans le panier';
  end if;

  v_ref := upper(substr(md5(gen_random_uuid()::text), 1, 6));
  insert into public.orders (reference, customer_name, phone, pickup_date, pickup_time, note, items, total)
  values (v_ref, trim(p_name), trim(p_phone), p_pickup_date, p_pickup_time, nullif(trim(p_note), ''), v_items, v_total);
  return v_ref;
end $$;

revoke all on function public.place_order(text, text, date, text, text, jsonb) from public;
grant execute on function public.place_order(text, text, date, text, text, jsonb) to anon, authenticated;

-- Temps réel : le back-office voit arriver les commandes sans recharger
alter publication supabase_realtime add table public.orders;

-- Photos produits
insert into storage.buckets (id, name, public) values ('products', 'products', true)
on conflict (id) do nothing;

create policy "photos produits lisibles" on storage.objects for select using (bucket_id = 'products');
create policy "admins envoient des photos" on storage.objects for insert with check (bucket_id = 'products' and public.is_admin());
create policy "admins remplacent des photos" on storage.objects for update using (bucket_id = 'products' and public.is_admin());
create policy "admins suppriment des photos" on storage.objects for delete using (bucket_id = 'products' and public.is_admin());

-- Catalogue de départ (exemples, à ajuster dans le back-office)
insert into public.products (name, category, unit, price, image_url, sort) values
  ('Mangue', 'Fruits', 'pièce', 1.50, 'images/produit-mangue.jpg', 1),
  ('Ananas', 'Fruits', 'pièce', 2.50, 'images/produit-ananas.jpg', 2),
  ('Bananes', 'Fruits', 'kg', 1.99, 'images/produit-banane.jpg', 3),
  ('Tomates', 'Légumes', 'kg', 2.50, 'images/produit-tomate.jpg', 4),
  ('Poivrons', 'Légumes', 'kg', 3.20, 'images/produit-poivron.jpg', 5),
  ('Oignons', 'Légumes', 'kg', 1.60, 'images/produit-oignon.jpg', 6),
  ('Banane plantain', 'Exotique', 'kg', 2.90, 'images/produit-plantain.jpg', 7),
  ('Igname', 'Exotique', 'kg', 3.50, 'images/produit-igname.jpg', 8),
  ('Gombo', 'Exotique', 'barquette', 2.80, 'images/produit-gombo.jpg', 9),
  ('Manioc', 'Exotique', 'kg', 2.90, 'images/produit-manioc.jpg', 10),
  ('Olives au détail', 'Épicerie', '250 g', 2.50, 'images/photo-5.jpg', 11),
  ('Œufs frais', 'Épicerie', 'boîte de 12', 3.90, 'images/produit-oeufs.jpg', 12),
  ('Pain chaud', 'Épicerie', 'pièce', 1.20, null, 13);
