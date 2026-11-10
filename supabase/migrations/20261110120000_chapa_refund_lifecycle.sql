-- Chapa refund lifecycle: idempotent reservations, per-refund references and verification.
begin;

create table if not exists public.payment_refunds (
  id uuid primary key default gen_random_uuid(),
  payment_id uuid not null references public.payments(id) on delete restrict,
  order_id uuid not null references public.orders(id) on delete restrict,
  provider text not null default 'chapa' references public.payment_provider_registry(provider),
  merchant_reference text not null unique,
  provider_reference text,
  idempotency_key text not null unique,
  amount_minor bigint not null check (amount_minor >= 100),
  requested_amount_minor bigint,
  request_full_refund boolean not null default false,
  currency text not null default 'ETB' check (currency = 'ETB'),
  reason text not null check (char_length(reason) between 1 and 400),
  status text not null default 'requested'
    check (status in ('requested','pending','succeeded','failed','review')),
  provider_status text,
  provider_payload jsonb not null default '{}'::jsonb,
  error_message text,
  requested_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  verified_at timestamptz,
  constraint payment_refunds_provider_chapa_check check (provider = 'chapa'),
  constraint payment_refunds_merchant_reference_length check (char_length(merchant_reference) between 1 and 20),
  constraint payment_refunds_idempotency_length check (char_length(idempotency_key) between 8 and 128)
);

create unique index if not exists payment_refunds_provider_reference_uidx
  on public.payment_refunds(provider, provider_reference)
  where provider_reference is not null;
create index if not exists payment_refunds_payment_status_idx
  on public.payment_refunds(payment_id, status, created_at desc);
create index if not exists payment_refunds_created_at_idx
  on public.payment_refunds(created_at desc);

-- A partially refunded payment remains refundable up to its verified balance.
alter table public.payments drop constraint if exists payments_status_check;
alter table public.payments add constraint payments_status_check
  check (status = any (array['initiated','pending','succeeded','failed','review','cancelled','refunded','partially_refunded']));

alter table public.payment_refunds enable row level security;
revoke all on table public.payment_refunds from public, anon, authenticated;
grant all on table public.payment_refunds to service_role;

create or replace function public.reserve_chapa_refund(
  p_payment_id uuid,
  p_amount_minor bigint,
  p_reason text,
  p_idempotency_key text,
  p_requested_by uuid
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_payment public.payments%rowtype;
  v_existing public.payment_refunds%rowtype;
  v_refund public.payment_refunds%rowtype;
  v_reserved bigint := 0;
  v_available bigint := 0;
  v_amount bigint := 0;
  v_full boolean := false;
  v_merchant_reference text;
begin
  if p_payment_id is null or p_requested_by is null then
    raise exception 'Payment and requesting administrator are required';
  end if;
  if p_reason is null or char_length(btrim(p_reason)) not between 1 and 400 then
    raise exception 'Refund reason must be from 1 to 400 characters';
  end if;
  if p_idempotency_key is null or p_idempotency_key !~ '^[A-Za-z0-9._:-]{8,128}$' then
    raise exception 'A valid idempotency key from 8 to 128 characters is required';
  end if;

  -- Same key and same payload always returns the original reservation.
  select * into v_existing
  from public.payment_refunds
  where idempotency_key = p_idempotency_key
  for update;
  if found then
    if v_existing.payment_id <> p_payment_id
       or v_existing.requested_amount_minor is distinct from p_amount_minor
       or v_existing.reason <> btrim(p_reason) then
      raise exception 'Idempotency key was already used for a different refund request';
    end if;
    return jsonb_build_object(
      'refund_id', v_existing.id,
      'merchant_reference', v_existing.merchant_reference,
      'provider_reference', v_existing.provider_reference,
      'amount_minor', v_existing.amount_minor,
      'currency', v_existing.currency,
      'status', v_existing.status,
      'request_full_refund', v_existing.request_full_refund,
      'duplicate', true
    );
  end if;

  select * into v_payment
  from public.payments
  where id = p_payment_id
  for update;
  if not found then raise exception 'Payment not found'; end if;
  if v_payment.provider <> 'chapa' then raise exception 'Only Chapa payments can use this refund endpoint'; end if;
  if v_payment.currency <> 'ETB' then raise exception 'Only ETB payments can be refunded through this workflow'; end if;
  if v_payment.status not in ('succeeded','partially_refunded') then raise exception 'Payment must be verified and successful before a refund can be requested'; end if;
  if coalesce(v_payment.provider_payment_reference, v_payment.provider_reference) is null then
    raise exception 'Verified Chapa payment reference is missing';
  end if;

  if exists (
    select 1 from public.payment_refund_alerts a
    where a.payment_id = v_payment.id and a.review_status = 'manual_review'
  ) then
    raise exception 'This payment has an unresolved provider refund notice; reconcile it before creating another refund';
  end if;

  select coalesce(sum(r.amount_minor), 0)::bigint into v_reserved
  from public.payment_refunds r
  where r.payment_id = v_payment.id and r.status in ('requested','pending','review');

  v_available := v_payment.amount_minor - coalesce(v_payment.refunded_amount_minor, 0) - v_reserved;
  if v_available < 100 then raise exception 'No refundable balance remains'; end if;

  if p_amount_minor is null then
    if coalesce(v_payment.refunded_amount_minor, 0) <> 0 or v_reserved <> 0 then
      raise exception 'After a partial refund, provide the exact remaining amount for the next refund';
    end if;
    v_amount := v_available;
    v_full := true;
  else
    if p_amount_minor < 100 then raise exception 'Refund amount must be at least 100 minor units'; end if;
    if p_amount_minor > v_available then raise exception 'Refund amount exceeds the remaining refundable balance'; end if;
    v_amount := p_amount_minor;
    v_full := false;
  end if;

  v_merchant_reference := 'TR' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 18));
  insert into public.payment_refunds(
    payment_id, order_id, provider, merchant_reference, idempotency_key,
    amount_minor, requested_amount_minor, request_full_refund,
    currency, reason, status, requested_by
  ) values (
    v_payment.id, v_payment.order_id, 'chapa', v_merchant_reference, p_idempotency_key,
    v_amount, p_amount_minor, v_full, 'ETB', btrim(p_reason), 'requested', p_requested_by
  )
  returning * into v_refund;

  return jsonb_build_object(
    'refund_id', v_refund.id,
    'merchant_reference', v_refund.merchant_reference,
    'provider_reference', v_refund.provider_reference,
    'amount_minor', v_refund.amount_minor,
    'currency', v_refund.currency,
    'status', v_refund.status,
    'request_full_refund', v_refund.request_full_refund,
    'duplicate', false
  );
end;
$function$;

create or replace function public.record_chapa_refund_result(
  p_refund_id uuid,
  p_provider_reference text,
  p_provider_status text,
  p_provider_payload jsonb default '{}'::jsonb,
  p_error_message text default null
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_refund public.payment_refunds%rowtype;
  v_payment public.payments%rowtype;
  v_status text;
  v_new_refunded_total bigint;
begin
  if p_refund_id is null then raise exception 'Refund id is required'; end if;
  select * into v_refund from public.payment_refunds where id = p_refund_id for update;
  if not found then raise exception 'Refund record not found'; end if;

  if v_refund.status in ('succeeded','failed') then
    return jsonb_build_object('refund_id',v_refund.id,'status',v_refund.status,'already_final',true);
  end if;

  if p_provider_reference is not null and v_refund.provider_reference is not null
     and p_provider_reference <> v_refund.provider_reference then
    raise exception 'Chapa refund reference mismatch';
  end if;

  v_status := upper(coalesce(p_provider_status,''));
  if v_status = 'SUCCESS' then
    v_status := 'succeeded';
  elsif v_status = 'PENDING' then
    v_status := 'pending';
  elsif v_status = 'FAILED' then
    v_status := 'failed';
  else
    v_status := 'review';
  end if;

  select * into v_payment from public.payments where id = v_refund.payment_id for update;
  if not found then raise exception 'Related payment not found'; end if;

  if v_status = 'review' then
    update public.payments set status='review', updated_at=now() where id=v_payment.id;
    update public.orders set status='payment_review', updated_at=now()
    where id=v_payment.order_id and status in ('paid','payment_review');
  elsif v_status = 'succeeded' then
    v_new_refunded_total := coalesce(v_payment.refunded_amount_minor,0) + v_refund.amount_minor;
    if v_new_refunded_total > v_payment.amount_minor then
      update public.payment_refunds
      set status='review', provider_status=upper(coalesce(p_provider_status,'UNKNOWN')),
          provider_reference=coalesce(provider_reference,p_provider_reference),
          provider_payload=coalesce(p_provider_payload,'{}'::jsonb),
          error_message='Verified refund would exceed the original payment amount',
          updated_at=now(), verified_at=now()
      where id=v_refund.id;
      return jsonb_build_object('refund_id',v_refund.id,'status','review','requires_manual_review',true);
    end if;

    update public.payments
    set refunded_amount_minor=v_new_refunded_total,
        status=case when v_new_refunded_total = amount_minor then 'refunded' else 'partially_refunded' end,
        updated_at=now()
    where id=v_payment.id;

    -- Keep the order in the existing review queue until ticket entitlement and
    -- organiser/platform split reconciliation are explicitly completed by staff.
    update public.orders
    set status='payment_review', updated_at=now()
    where id=v_payment.order_id and status in ('paid','payment_review');

    -- A cumulative webhook alert is reconciled only when its total exactly
    -- matches the independently verified total of individual refund records.
    update public.payment_refund_alerts
    set review_status='reconciled', reconciled_at=now()
    where payment_id=v_payment.id
      and review_status='manual_review'
      and original_amount_minor=v_payment.amount_minor
      and refunded_amount_minor=v_new_refunded_total;

    insert into public.payment_attempt_events(
      payment_id, order_id, provider, event_type, provider_event_reference, safe_metadata
    ) values (
      v_payment.id, v_payment.order_id, 'chapa', 'refund_notice',
      coalesce(p_provider_reference,v_refund.merchant_reference),
      jsonb_build_object('refund_id',v_refund.id,'refund_amount_minor',v_refund.amount_minor,
                         'refunded_total_minor',v_new_refunded_total,'provider_status','SUCCESS',
                         'source','verified_refund_api')
    );
  end if;

  update public.payment_refunds
  set status=v_status,
      provider_status=upper(coalesce(p_provider_status,'UNKNOWN')),
      provider_reference=coalesce(provider_reference,p_provider_reference),
      provider_payload=coalesce(p_provider_payload,'{}'::jsonb),
      error_message=p_error_message,
      updated_at=now(),
      verified_at=case when v_status in ('succeeded','failed','review') then now() else verified_at end
  where id=v_refund.id;

  return jsonb_build_object(
    'refund_id',v_refund.id,
    'status',v_status,
    'refunded_total_minor',case when v_status='succeeded' then v_new_refunded_total else coalesce(v_payment.refunded_amount_minor,0) end,
    'requires_manual_review',v_status='succeeded' or v_status='review'
  );
end;
$function$;

create or replace function public.get_tiqet_refunds_dashboard(p_limit integer default 50)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $function$
declare
  v_result jsonb;
begin
  if auth.uid() is null or not public.is_tiqet_admin() then
    raise exception 'Tiqet administrator permission required';
  end if;
  if p_limit is null or p_limit not between 1 and 100 then
    raise exception 'Limit must be from 1 to 100';
  end if;

  select jsonb_build_object(
    'currency','ETB',
    'summary',jsonb_build_object(
      'total', (select count(*) from public.payment_refunds),
      'open', (select count(*) from public.payment_refunds where status in ('requested','pending','review')),
      'succeeded', (select count(*) from public.payment_refunds where status='succeeded'),
      'failed', (select count(*) from public.payment_refunds where status='failed'),
      'orders_awaiting_reconciliation', (select count(*) from public.orders where status='payment_review')
    ),
    'refunds', coalesce((
      select jsonb_agg(x.item order by x.created_at desc)
      from (
        select jsonb_build_object(
          'id',r.id,'payment_id',r.payment_id,'order_id',r.order_id,
          'merchant_reference',r.merchant_reference,'provider_reference',r.provider_reference,
          'amount_minor',r.amount_minor,'currency',r.currency,'reason',r.reason,
          'status',r.status,'provider_status',r.provider_status,
          'error_message',r.error_message,'requested_by',r.requested_by,
          'created_at',r.created_at,'updated_at',r.updated_at,'verified_at',r.verified_at,
          'payment_status',p.status,'order_status',o.status::text,
          'payment_merchant_reference',p.merchant_reference
        ) item,r.created_at
        from public.payment_refunds r
        join public.payments p on p.id=r.payment_id
        join public.orders o on o.id=r.order_id
        order by r.created_at desc limit p_limit
      ) x
    ),'[]'::jsonb)
  ) into v_result;
  return v_result;
end;
$function$;


-- Webhook amounts are cumulative for the payment, not per-refund identifiers.
-- An alert is auto-reconciled only when it matches the amount already verified
-- through individual refund references.
create or replace function public.record_chapa_refund_notice(
  p_merchant_reference text,
  p_payload_sha256 text,
  p_event_name text,
  p_provider_status text,
  p_original_amount_minor bigint,
  p_refunded_amount_minor bigint,
  p_currency text,
  p_provider_payload jsonb
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_payment public.payments%rowtype;
  v_order public.orders%rowtype;
  v_alert_id uuid;
  v_reconciled boolean := false;
begin
  if p_event_name is null or p_event_name not in ('payment.partially_refunded','payment.fully_refunded') then
    raise exception 'Unsupported refund event';
  end if;
  if p_provider_status is null or p_provider_status not in ('partially_refunded','fully_refunded') then
    raise exception 'Unsupported refund status';
  end if;
  if p_currency is distinct from 'ETB' or p_payload_sha256 is null or p_payload_sha256 !~ '^[a-f0-9]{64}(uuid,bigint,text,text,uuid) from public, anon, authenticated;
grant execute on function public.reserve_chapa_refund(uuid,bigint,text,text,uuid) to service_role;
revoke all on function public.record_chapa_refund_result(uuid,text,text,jsonb,text) from public, anon, authenticated;
grant execute on function public.record_chapa_refund_result(uuid,text,text,jsonb,text) to service_role;
revoke all on function public.get_tiqet_refunds_dashboard(integer) from public, anon;
grant execute on function public.get_tiqet_refunds_dashboard(integer) to authenticated;

commit;
 then
    raise exception 'Invalid refund currency or payload digest';
  end if;
  if p_original_amount_minor is null or p_original_amount_minor <= 0
     or p_refunded_amount_minor is null or p_refunded_amount_minor <= 0
     or p_refunded_amount_minor > p_original_amount_minor then
    raise exception 'Invalid refund amount';
  end if;
  if p_event_name = 'payment.fully_refunded' and p_refunded_amount_minor <> p_original_amount_minor then
    raise exception 'Full refund amount does not match original payment';
  end if;
  if p_event_name = 'payment.partially_refunded' and p_refunded_amount_minor >= p_original_amount_minor then
    raise exception 'Partial refund amount is not partial';
  end if;

  select * into v_payment
  from public.payments
  where merchant_reference = p_merchant_reference
  for update;
  if not found then raise exception 'Payment reference not found'; end if;
  if v_payment.amount_minor <> p_original_amount_minor or v_payment.currency <> p_currency then
    raise exception 'Refund notice does not match original payment';
  end if;

  select * into v_order from public.orders where id = v_payment.order_id for update;
  if not found then raise exception 'Order not found'; end if;
  if v_order.status not in ('paid','payment_review','refunded') then
    raise exception 'Refund notice received for an order not marked paid';
  end if;

  insert into public.payment_refund_alerts(
    payment_id, order_id, merchant_reference, event_name, provider_status,
    original_amount_minor, refunded_amount_minor, currency, payload_sha256, provider_payload
  ) values (
    v_payment.id, v_order.id, p_merchant_reference, p_event_name, p_provider_status,
    p_original_amount_minor, p_refunded_amount_minor, p_currency, p_payload_sha256,
    coalesce(p_provider_payload,'{}'::jsonb)
  ) on conflict (payload_sha256) do nothing
  returning id into v_alert_id;

  insert into public.webhook_events(provider, payload_sha256, merchant_reference)
  values ('chapa_refund', p_payload_sha256, p_merchant_reference)
  on conflict (provider, payload_sha256) do nothing;

  v_reconciled := coalesce(v_payment.refunded_amount_minor,0) = p_refunded_amount_minor;
  if v_reconciled then
    update public.payment_refund_alerts
    set review_status='reconciled', reconciled_at=now()
    where payload_sha256=p_payload_sha256;
  else
    update public.payments
    set status='review',
        provider_payload=coalesce(provider_payload,'{}'::jsonb) ||
          jsonb_build_object('refund_notice_received',true,'latest_refund_event',p_event_name,
                             'latest_refunded_amount_minor',p_refunded_amount_minor),
        updated_at=now()
    where id=v_payment.id and status <> 'refunded';

    update public.orders set status='payment_review', updated_at=now()
    where id=v_order.id and status in ('paid','payment_review');
  end if;

  return jsonb_build_object(
    'recorded',true,'duplicate',v_alert_id is null,
    'order_id',v_order.id,
    'manual_reconciliation_required',not v_reconciled
  );
end;
$function$;

revoke all on function public.reserve_chapa_refund(uuid,bigint,text,text,uuid) from public, anon, authenticated;
grant execute on function public.reserve_chapa_refund(uuid,bigint,text,text,uuid) to service_role;
revoke all on function public.record_chapa_refund_result(uuid,text,text,jsonb,text) from public, anon, authenticated;
grant execute on function public.record_chapa_refund_result(uuid,text,text,jsonb,text) to service_role;
revoke all on function public.get_tiqet_refunds_dashboard(integer) from public, anon;
grant execute on function public.get_tiqet_refunds_dashboard(integer) to authenticated;

commit;
