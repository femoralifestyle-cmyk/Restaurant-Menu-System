-- Atomic order placement, status transitions, payment confirmation and loyalty.
create or replace function public.place_table_order(p_restaurant_id uuid,p_qr_token uuid,p_items jsonb,p_payment_method text,p_instructions text default null,p_idempotency_key uuid default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_customer uuid:=auth.uid(); v_table uuid; v_order uuid; v_number bigint; v_item jsonb; v_product public.products%rowtype; v_qty int; v_subtotal numeric(12,2):=0; v_existing uuid;
begin
 if v_customer is null then raise exception 'Authentication required'; end if;
 if p_payment_method not in ('cash','online') then raise exception 'Invalid payment method'; end if;
 if p_items is null or jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 or jsonb_array_length(p_items)>50 then raise exception 'Invalid items'; end if;
 select t.id into v_table from public.restaurant_tables t join public.restaurants r on r.id=t.restaurant_id where t.restaurant_id=p_restaurant_id and t.qr_token=p_qr_token and t.is_active and r.is_active;
 if v_table is null then raise exception 'Invalid or inactive table QR'; end if;
 if p_idempotency_key is not null then
  perform pg_advisory_xact_lock(hashtextextended(v_customer::text||p_idempotency_key::text,0));
  select id into v_existing from public.orders where customer_id=v_customer and idempotency_key=p_idempotency_key;
  if v_existing is not null then return jsonb_build_object('success',true,'duplicate',true,'order_id',v_existing); end if;
 end if;
 for v_item in select value from jsonb_array_elements(p_items) loop
  if coalesce(v_item->>'quantity','') !~ '^[0-9]+$' then raise exception 'Invalid quantity'; end if;
  v_qty:=(v_item->>'quantity')::int; if v_qty<1 or v_qty>50 then raise exception 'Quantity must be 1 to 50'; end if;
  select * into v_product from public.products where id=(v_item->>'product_id')::uuid and restaurant_id=p_restaurant_id and is_available for share;
  if not found then raise exception 'Product unavailable'; end if;
  v_subtotal:=v_subtotal+v_product.price*v_qty;
 end loop;
 insert into public.orders(restaurant_id,customer_id,table_id,order_type,source,status,subtotal,tax_amount,total_amount,payment_method,payment_status,special_instructions,idempotency_key)
 values(p_restaurant_id,v_customer,v_table,'dine_in','table_qr','pending',v_subtotal,0,v_subtotal,p_payment_method,'pending',left(p_instructions,1000),p_idempotency_key)
 returning id,order_number into v_order,v_number;
 for v_item in select value from jsonb_array_elements(p_items) loop
  v_qty:=(v_item->>'quantity')::int;
  select * into v_product from public.products where id=(v_item->>'product_id')::uuid and restaurant_id=p_restaurant_id and is_available;
  insert into public.order_items(order_id,product_id,product_name,unit_price,quantity,total_price,special_instructions)
  values(v_order,v_product.id,v_product.name,v_product.price,v_qty,v_product.price*v_qty,left(v_item->>'instructions',500));
 end loop;
 insert into public.payments(order_id,amount,method,status) values(v_order,v_subtotal,p_payment_method,'pending');
 return jsonb_build_object('success',true,'order_id',v_order,'order_number',v_number,'table_id',v_table,'subtotal',v_subtotal,'tax',0,'total',v_subtotal,'currency','INR','payment_status','pending');
end; $$;

create or replace function public.award_order_stamp() returns trigger language plpgsql security definer set search_path='' as $$
declare v_threshold numeric(12,2); v_required int; v_balance int;
begin
 if new.status<>'served' or new.payment_status<>'paid' or new.completed_at is null then return new; end if;
 if old.status='served' and old.payment_status='paid' then return new; end if;
 select minimum_stamp_purchase,stamps_required into v_threshold,v_required from public.restaurant_settings where restaurant_id=new.restaurant_id and loyalty_enabled;
 if not found or new.total_amount<v_threshold then return new; end if;
 insert into public.loyalty_accounts(restaurant_id,customer_id) values(new.restaurant_id,new.customer_id) on conflict(restaurant_id,customer_id) do nothing;
 insert into public.loyalty_transactions(restaurant_id,customer_id,order_id,transaction_type,stamps_changed,description)
 values(new.restaurant_id,new.customer_id,new.id,'stamp_earned',1,'Qualifying paid and served purchase')
 on conflict(order_id) where transaction_type='stamp_earned' do nothing;
 if not found then return new; end if;
 select stamp_balance into v_balance from public.loyalty_accounts where restaurant_id=new.restaurant_id and customer_id=new.customer_id for update;
 v_balance:=v_balance+1;
 update public.loyalty_accounts set stamp_balance=case when v_balance>=v_required then 0 else v_balance end,
 lifetime_stamps=lifetime_stamps+1,
 available_rewards=available_rewards+case when v_balance>=v_required then 1 else 0 end,updated_at=now()
 where restaurant_id=new.restaurant_id and customer_id=new.customer_id;
 if v_balance>=v_required then
  insert into public.loyalty_transactions(restaurant_id,customer_id,order_id,transaction_type,rewards_changed,description)
  values(new.restaurant_id,new.customer_id,new.id,'reward_unlocked',1,'Loyalty stamp threshold reached');
 end if;
 return new;
end; $$;
create trigger award_stamp_after_order_update after update of status,payment_status on public.orders for each row execute function public.award_order_stamp();

create or replace function public.update_order_status(p_order_id uuid,p_status text) returns jsonb language plpgsql security definer set search_path='' as $$
declare v_restaurant uuid; v_current text;
begin
 select restaurant_id,status into v_restaurant,v_current from public.orders where id=p_order_id for update;
 if not found then raise exception 'Order not found'; end if;
 if not public.has_restaurant_role(v_restaurant,array['owner','admin','manager','staff','kitchen']) then raise exception 'Permission denied'; end if;
 if not ((v_current='pending' and p_status in ('accepted','cancelled')) or (v_current='accepted' and p_status in ('preparing','cancelled')) or (v_current='preparing' and p_status in ('ready','cancelled')) or (v_current='ready' and p_status='served')) then raise exception 'Invalid status transition'; end if;
 update public.orders set status=p_status,completed_at=case when p_status='served' then now() else completed_at end,updated_at=now() where id=p_order_id;
 return jsonb_build_object('success',true,'order_id',p_order_id,'status',p_status);
end; $$;

create or replace function public.confirm_cash_payment(p_order_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare v_restaurant uuid; v_method text;
begin
 select restaurant_id,payment_method into v_restaurant,v_method from public.orders where id=p_order_id and payment_status='pending' for update;
 if not found then raise exception 'Pending order not found'; end if;
 if v_method<>'cash' then raise exception 'Not a cash order'; end if;
 if not public.has_restaurant_role(v_restaurant,array['owner','admin','manager','staff']) then raise exception 'Permission denied'; end if;
 update public.payments set status='success' where order_id=p_order_id and method='cash' and status='pending';
 update public.orders set payment_status='paid',updated_at=now() where id=p_order_id;
 return jsonb_build_object('success',true,'payment_status','paid');
end; $$;

create or replace function public.redeem_reward(p_reward_id uuid,p_client_request_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare v_customer uuid:=auth.uid(); v_restaurant uuid; v_account public.loyalty_accounts%rowtype; v_redemption uuid;
begin
 if v_customer is null then raise exception 'Authentication required'; end if;
 if p_client_request_id is null then raise exception 'Request id required'; end if;
 perform pg_advisory_xact_lock(hashtextextended(v_customer::text||p_client_request_id::text,0));
 select id into v_redemption from public.reward_redemptions where customer_id=v_customer and client_request_id=p_client_request_id;
 if found then return jsonb_build_object('success',true,'duplicate',true,'redemption_id',v_redemption); end if;
 select restaurant_id into v_restaurant from public.rewards where id=p_reward_id and is_active;
 if not found then raise exception 'Reward unavailable'; end if;
 select * into v_account from public.loyalty_accounts where restaurant_id=v_restaurant and customer_id=v_customer for update;
 if not found or v_account.available_rewards<1 then raise exception 'No reward credit available'; end if;
 update public.loyalty_accounts set available_rewards=available_rewards-1,updated_at=now() where id=v_account.id;
 insert into public.reward_redemptions(restaurant_id,customer_id,reward_id,status,client_request_id) values(v_restaurant,v_customer,p_reward_id,'pending',p_client_request_id) returning id into v_redemption;
 insert into public.loyalty_transactions(restaurant_id,customer_id,transaction_type,rewards_changed,description) values(v_restaurant,v_customer,'reward_redeemed',-1,'Reward credit reserved for redemption');
 return jsonb_build_object('success',true,'redemption_id',v_redemption,'status','pending');
end; $$;

revoke all on function public.place_table_order(uuid,uuid,jsonb,text,text,uuid) from public,anon;
grant execute on function public.place_table_order(uuid,uuid,jsonb,text,text,uuid) to authenticated;
revoke all on function public.update_order_status(uuid,text) from public,anon;
grant execute on function public.update_order_status(uuid,text) to authenticated;
revoke all on function public.confirm_cash_payment(uuid) from public,anon;
grant execute on function public.confirm_cash_payment(uuid) to authenticated;
revoke all on function public.redeem_reward(uuid,uuid) from public,anon;
grant execute on function public.redeem_reward(uuid,uuid) to authenticated;
