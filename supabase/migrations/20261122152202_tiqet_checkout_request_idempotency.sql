-- Persist checkout request keys so client retries reuse the same order and inventory hold.
begin;

alter table public.orders
  add column if not exists client_idempotency_key uuid;

create unique index if not exists orders_buyer_client_idempotency_key_uidx
  on public.orders(buyer_id, client_idempotency_key)
  where client_idempotency_key is not null;

create or replace function public.create_order_hold(
  p_ticket_type_id uuid,
  p_quantity integer,
  p_idempotency_key uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_user uuid := auth.uid();
  v_type public.ticket_types%rowtype;
  v_event public.events%rowtype;
  v_order_id uuid;
  v_reference text;
  v_subtotal numeric(12,2);
  v_fee numeric(12,2);
  v_total numeric(12,2);
  v_fee_rate numeric(6,5);
  v_fee_min numeric(12,2);
  v_fee_max numeric(12,2);
  v_item_id uuid;
  v_existing public.orders%rowtype;
  v_existing_item public.order_items%rowtype;
begin
  if v_user is null then raise exception 'Authentication required'; end if;
  if p_quantity is null or p_quantity < 1 or p_quantity > 10 then
    raise exception 'Quantity must be between 1 and 10';
  end if;
  if p_ticket_type_id is null or p_idempotency_key is null then
    raise exception 'A ticket type and checkout request key are required';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(v_user::text || ':' || p_idempotency_key::text, 0)
  );

  select o.* into v_existing
  from public.orders o
  where o.buyer_id = v_user
    and o.client_idempotency_key = p_idempotency_key
  for update;

  if found then
    select oi.* into v_existing_item
    from public.order_items oi
    where oi.order_id = v_existing.id
    limit 1;

    if not found
       or v_existing_item.ticket_type_id <> p_ticket_type_id
       or v_existing_item.quantity <> p_quantity then
      raise exception 'This checkout request key was already used for different ticket details';
    end if;

    if (v_existing.status = 'payment_pending'::public.order_status and v_existing.hold_expires_at > now())
       or v_existing.status in ('paid'::public.order_status, 'payment_review'::public.order_status) then
      return jsonb_build_object(
        'order_id', v_existing.id,
        'order_item_id', v_existing_item.id,
        'merchant_reference', v_existing.merchant_reference,
        'quantity', v_existing_item.quantity,
        'subtotal_etb', v_existing.subtotal_etb,
        'buyer_service_fee_etb', v_existing.fees_etb,
        'total_etb', v_existing.total_etb,
        'amount_minor', round(v_existing.total_etb * 100)::bigint,
        'currency', v_existing.currency,
        'hold_expires_at', v_existing.hold_expires_at,
        'order_status', v_existing.status::text,
        'idempotent_replay', true,
        'already_paid', v_existing.status = 'paid'::public.order_status,
        'payment_review', v_existing.status = 'payment_review'::public.order_status
      );
    end if;

    raise exception 'This checkout attempt is no longer active. Start a new checkout attempt.';
  end if;

  for v_order_id in
    select o.id
    from public.orders o
    join public.order_items oi on oi.order_id = o.id
    where oi.ticket_type_id = p_ticket_type_id
      and o.status = 'payment_pending'::public.order_status
      and o.hold_expires_at <= now()
    for update of o
  loop
    update public.orders
      set status = 'expired'::public.order_status, updated_at = now()
      where id = v_order_id and status = 'payment_pending'::public.order_status;

    update public.ticket_types t
      set quantity_reserved = greatest(0, t.quantity_reserved - coalesce((
        select sum(oi.quantity)
        from public.order_items oi
        where oi.order_id = v_order_id and oi.ticket_type_id = t.id
      ),0)),
      updated_at = now()
      where t.id = p_ticket_type_id;
  end loop;

  select * into v_type from public.ticket_types
  where id = p_ticket_type_id for update;
  if not found then raise exception 'Ticket type not found'; end if;

  select * into v_event from public.events where id = v_type.event_id;
  if v_event.status <> 'published'::public.event_status
     or v_event.approval_status <> 'approved' then
    raise exception 'Event is not available for sale';
  end if;
  if v_type.sales_start is not null and v_type.sales_start > now() then raise exception 'Ticket sales have not started'; end if;
  if v_type.sales_end is not null and v_type.sales_end <= now() then raise exception 'Ticket sales have ended'; end if;
  if p_quantity > v_type.per_order_limit then raise exception 'Quantity exceeds the per-order limit'; end if;
  if (v_type.quantity_total - v_type.quantity_reserved - v_type.quantity_sold) < p_quantity then
    raise exception 'Not enough tickets are available';
  end if;

  v_subtotal := round(v_type.price_etb * p_quantity, 2);
  select buyer_fee_rate, buyer_fee_min_etb, buyer_fee_max_etb
    into v_fee_rate, v_fee_min, v_fee_max
  from public.platform_financial_settings where singleton = true;

  v_fee := case
    when v_subtotal = 0 then 0
    else least(v_fee_max, greatest(v_fee_min, round(v_subtotal * v_fee_rate, 2)))
  end;
  v_total := v_subtotal + v_fee;
  v_order_id := gen_random_uuid();
  v_reference := 'TQ' || upper(substr(encode(extensions.gen_random_bytes(12),'hex'),1,18));

  insert into public.orders(
    id,buyer_id,status,subtotal_etb,fees_etb,total_etb,merchant_reference,hold_expires_at,client_idempotency_key
  ) values (
    v_order_id,v_user,'payment_pending'::public.order_status,v_subtotal,v_fee,v_total,
    v_reference,now()+interval '10 minutes',p_idempotency_key
  );

  insert into public.order_items(
    order_id,ticket_type_id,event_id,ticket_name_snapshot,unit_price_etb,quantity,line_total_etb
  ) values (
    v_order_id,v_type.id,v_event.id,v_type.name,v_type.price_etb,p_quantity,v_subtotal
  ) returning id into v_item_id;

  update public.ticket_types
  set quantity_reserved = quantity_reserved + p_quantity, updated_at = now()
  where id = v_type.id;

  return jsonb_build_object(
    'order_id',v_order_id,'order_item_id',v_item_id,'merchant_reference',v_reference,
    'quantity',p_quantity,'subtotal_etb',v_subtotal,'buyer_service_fee_etb',v_fee,
    'total_etb',v_total,'amount_minor',round(v_total*100)::bigint,'currency','ETB',
    'hold_expires_at',now()+interval '10 minutes','order_status','payment_pending',
    'idempotent_replay',false,'already_paid',false,'payment_review',false
  );
end;
$function$;

create or replace function public.create_order_hold(
  p_ticket_type_id uuid,
  p_quantity integer
) returns jsonb
language sql
security definer
set search_path = ''
as $function$
  select public.create_order_hold(p_ticket_type_id, p_quantity, gen_random_uuid());
$function$;

revoke all on function public.create_order_hold(uuid,integer,uuid) from public, anon;
revoke all on function public.create_order_hold(uuid,integer) from public, anon;
grant execute on function public.create_order_hold(uuid,integer,uuid) to authenticated, service_role;
grant execute on function public.create_order_hold(uuid,integer) to authenticated, service_role;

commit;
