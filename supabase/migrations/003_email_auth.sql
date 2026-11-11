-- Email/password authentication profile support.
alter table public.profiles add column if not exists email text;

create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 insert into public.profiles(id,email,phone,full_name)
 values(new.id,new.email,new.phone,new.raw_user_meta_data->>'full_name')
 on conflict(id) do update set email=excluded.email, phone=excluded.phone;
 return new;
end; $$;

-- Backfill existing profiles from Supabase Auth.
update public.profiles p set email=u.email
from auth.users u where u.id=p.id and p.email is distinct from u.email;
