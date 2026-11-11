create extension if not exists pgcrypto;

create table public.restaurants (
 id uuid primary key default gen_random_uuid(), name text not null, slug text unique not null,
 logo_url text, phone text, address text, currency text not null default 'INR',
 is_active boolean not null default true, created_at timestamptz not null default now()
);
create table public.profiles (
 id uuid primary key references auth.users(id) on delete cascade,
 full_name text, phone text unique, created_at timestamptz not null default now()
);
create table public.restaurant_members (
 id uuid primary key default gen_random_uuid(), restaurant_id uuid not null references public.restaurants(id) on delete cascade,
 user_id uuid not null references public.profiles(id) on delete cascade,
 role text not null check(role in ('owner','admin','manager','staff','kitchen')),
 created_at timestamptz not null default now(), unique(restaurant_id,user_id)
);
create table public.categories (
 id uuid primary key default gen_random_uuid(), restaurant_id uuid not null references public.restaurants(id) on delete cascade,
 name text not null, description text, image_url text, sort_order int not null default 0,
 is_active boolean not null default true, created_at timestamptz not null default now()
);
create table public.products (
 id uuid primary key default gen_random_uuid(), restaurant_id uuid not null references public.restaurants(id) on delete cascade,
 category_id uuid references public.categories(id) on delete set null, name text not null,
 description text, image_url text, price numeric(12,2) not null check(price>=0),
 food_type text not null default 'veg' check(food_type in ('veg','non_veg','vegan')),
 is_available boolean not null default true, is_featured boolean not null default false,
 sort_order int not null default 0, created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table public.restaurant_tables (
 id uuid primary key default gen_random_uuid(), restaurant_id uuid not null references public.restaurants(id) on delete cascade,
 table_number text not null, qr_token uuid not null unique default gen_random_uuid(), capacity int not null default 4,
 is_active boolean not null default true, created_at timestamptz not null default now(), unique(restaurant_id,table_number)
);
create table public.orders (
 id uuid primary key default gen_random_uuid(), order_number bigint generated always as identity unique,
 restaurant_id uuid not null references public.restaurants(id), customer_id uuid not null references public.profiles(id),
 table_id uuid references public.restaurant_tables(id), order_type text not null default 'dine_in' check(order_type in ('dine_in','takeaway','delivery')),
 source text not null default 'table_qr' check(source in ('table_qr','website','admin')),
 status text not null default 'pending' check(status in ('pending','accepted','preparing','ready','served','cancelled')),
 subtotal numeric(12,2) not null default 0 check(subtotal>=0), tax_amount numeric(12,2) not null default 0 check(tax_amount>=0),
 discount_amount numeric(12,2) not null default 0 check(discount_amount>=0), total_amount numeric(12,2) not null default 0 check(total_amount>=0),
 payment_status text not null default 'pending' check(payment_status in ('pending','paid','failed','refunded')),
 payment_method text not null check(payment_method in ('cash','online')), special_instructions text,
 idempotency_key uuid, created_at timestamptz not null default now(), updated_at timestamptz not null default now(), completed_at timestamptz,
 unique(customer_id,idempotency_key)
);
create table public.order_items (
 id uuid primary key default gen_random_uuid(), order_id uuid not null references public.orders(id) on delete cascade,
 product_id uuid references public.products(id) on delete set null, product_name text not null,
 unit_price numeric(12,2) not null, quantity int not null check(quantity between 1 and 50),
 total_price numeric(12,2) not null, special_instructions text, created_at timestamptz not null default now()
);
create table public.payments (
 id uuid primary key default gen_random_uuid(), order_id uuid not null references public.orders(id),
 amount numeric(12,2) not null check(amount>=0), method text not null check(method in ('cash','online')),
 transaction_reference text, status text not null default 'pending' check(status in ('pending','success','failed','refunded')),
 created_at timestamptz not null default now()
);
create table public.loyalty_accounts (
 id uuid primary key default gen_random_uuid(), restaurant_id uuid not null references public.restaurants(id),
 customer_id uuid not null references public.profiles(id), stamp_balance int not null default 0 check(stamp_balance between 0 and 9),
 lifetime_stamps int not null default 0, available_rewards int not null default 0 check(available_rewards>=0),
 created_at timestamptz not null default now(), updated_at timestamptz not null default now(), unique(restaurant_id,customer_id)
);
create table public.loyalty_transactions (
 id uuid primary key default gen_random_uuid(), restaurant_id uuid not null references public.restaurants(id),
 customer_id uuid not null references public.profiles(id), order_id uuid references public.orders(id),
 transaction_type text not null check(transaction_type in ('stamp_earned','reward_unlocked','reward_redeemed','stamp_adjustment')),
 stamps_changed int not null default 0, rewards_changed int not null default 0, description text,
 created_at timestamptz not null default now()
);
create unique index one_stamp_per_order on public.loyalty_transactions(order_id) where transaction_type='stamp_earned';
create table public.rewards (
 id uuid primary key default gen_random_uuid(), restaurant_id uuid not null references public.restaurants(id),
 product_id uuid references public.products(id) on delete set null, name text not null, description text,
 image_url text, is_active boolean not null default true, created_at timestamptz not null default now()
);
create table public.reward_redemptions (
 id uuid primary key default gen_random_uuid(), restaurant_id uuid not null references public.restaurants(id),
 customer_id uuid not null references public.profiles(id), reward_id uuid not null references public.rewards(id),
 status text not null default 'pending' check(status in ('pending','redeemed','cancelled')),
 redeemed_by uuid references public.profiles(id), client_request_id uuid not null,
 created_at timestamptz not null default now(), redeemed_at timestamptz,
 unique(customer_id,client_request_id)
);
create table public.restaurant_settings (
 id uuid primary key default gen_random_uuid(), restaurant_id uuid not null unique references public.restaurants(id),
 loyalty_enabled boolean not null default true, minimum_stamp_purchase numeric(12,2) not null default 1000 check(minimum_stamp_purchase>=0),
 stamps_required int not null default 10 check(stamps_required>0), tax_percentage numeric(5,2) not null default 0,
 service_charge_percentage numeric(5,2) not null default 0, accept_online_orders boolean not null default true,
 created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create index orders_restaurant_status_idx on public.orders(restaurant_id,status);
create index orders_customer_idx on public.orders(customer_id,created_at desc);
create index products_category_idx on public.products(category_id);
create index loyalty_history_idx on public.loyalty_transactions(customer_id,created_at desc);

create or replace function public.handle_new_user() returns trigger language plpgsql security definer set search_path='' as $$
begin
 insert into public.profiles(id,phone,full_name) values(new.id,new.phone,new.raw_user_meta_data->>'full_name') on conflict(id) do nothing;
 return new;
end; $$;
create trigger on_auth_user_created after insert on auth.users for each row execute function public.handle_new_user();

create or replace function public.is_restaurant_member(target_restaurant uuid) returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.restaurant_members m where m.restaurant_id=target_restaurant and m.user_id=(select auth.uid()));
$$;
create or replace function public.has_restaurant_role(target_restaurant uuid, allowed_roles text[]) returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.restaurant_members m where m.restaurant_id=target_restaurant and m.user_id=(select auth.uid()) and m.role=any(allowed_roles));
$$;

alter table public.restaurants enable row level security;
alter table public.profiles enable row level security;
alter table public.restaurant_members enable row level security;
alter table public.categories enable row level security;
alter table public.products enable row level security;
alter table public.restaurant_tables enable row level security;
alter table public.orders enable row level security;
alter table public.order_items enable row level security;
alter table public.payments enable row level security;
alter table public.loyalty_accounts enable row level security;
alter table public.loyalty_transactions enable row level security;
alter table public.rewards enable row level security;
alter table public.reward_redemptions enable row level security;
alter table public.restaurant_settings enable row level security;

create policy restaurants_public_read on public.restaurants for select to anon,authenticated using(is_active);
create policy profiles_self_read on public.profiles for select to authenticated using(id=(select auth.uid()));
create policy profiles_self_update on public.profiles for update to authenticated using(id=(select auth.uid())) with check(id=(select auth.uid()));
create policy members_read_self_or_admin on public.restaurant_members for select to authenticated using(user_id=(select auth.uid()) or public.has_restaurant_role(restaurant_id,array['owner','admin']));
create policy categories_public_read on public.categories for select to anon,authenticated using(is_active);
create policy products_public_read on public.products for select to anon,authenticated using(is_available);
create policy categories_staff_manage on public.categories for all to authenticated using(public.has_restaurant_role(restaurant_id,array['owner','admin','manager'])) with check(public.has_restaurant_role(restaurant_id,array['owner','admin','manager']));
create policy products_staff_manage on public.products for all to authenticated using(public.has_restaurant_role(restaurant_id,array['owner','admin','manager'])) with check(public.has_restaurant_role(restaurant_id,array['owner','admin','manager']));
create policy orders_customer_or_staff_read on public.orders for select to authenticated using(customer_id=(select auth.uid()) or public.is_restaurant_member(restaurant_id));
create policy order_items_customer_or_staff_read on public.order_items for select to authenticated using(exists(select 1 from public.orders o where o.id=order_id and (o.customer_id=(select auth.uid()) or public.is_restaurant_member(o.restaurant_id))));
create policy payments_staff_read on public.payments for select to authenticated using(exists(select 1 from public.orders o where o.id=order_id and public.is_restaurant_member(o.restaurant_id)));
create policy loyalty_account_self_read on public.loyalty_accounts for select to authenticated using(customer_id=(select auth.uid()) or public.is_restaurant_member(restaurant_id));
create policy loyalty_history_self_read on public.loyalty_transactions for select to authenticated using(customer_id=(select auth.uid()) or public.is_restaurant_member(restaurant_id));
create policy rewards_public_read on public.rewards for select to anon,authenticated using(is_active);
create policy rewards_staff_manage on public.rewards for all to authenticated using(public.has_restaurant_role(restaurant_id,array['owner','admin','manager'])) with check(public.has_restaurant_role(restaurant_id,array['owner','admin','manager']));
create policy redemptions_self_or_staff_read on public.reward_redemptions for select to authenticated using(customer_id=(select auth.uid()) or public.is_restaurant_member(restaurant_id));
create policy tables_staff_manage on public.restaurant_tables for all to authenticated using(public.has_restaurant_role(restaurant_id,array['owner','admin','manager'])) with check(public.has_restaurant_role(restaurant_id,array['owner','admin','manager']));
create policy settings_admin_read on public.restaurant_settings for select to authenticated using(public.has_restaurant_role(restaurant_id,array['owner','admin','manager']));

-- Realtime events for order queue and tracking.
alter publication supabase_realtime add table public.orders;
alter publication supabase_realtime add table public.order_items;
