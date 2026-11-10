begin;

create table if not exists public.chapa_refund_operations (
  id uuid primary key default gen_random_uuid(),
  payment_id uuid not null references public.payments(id) on delete restrict,
  order_id uuid not null references public.orders(id) on delete restrict,
  merchant_reference text not null unique,
  provider_reference text unique,
  idempotency_key text not null unique,
  requested_amount_minor bigint,
  amount_minor bigint not null check (amount_minor >= 100),
  request_full_refund boolean not null default false,
  reason text not null check (char_length(reason) between 1 and 400),
  status text not null default 'requested'
    check (status in ('requested','pending','submission_unknown','succeeded','failed','review')),
  error_message text,
  provider_payload jsonb not null default '{}'::jsonb,
  requested_by uuid,
  verified_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint chapa_refund_operations_full_amount_check
    check ((request_full_refund and requested_amount_minor is null) or
           (not request_full_refund and requested_amount_minor = amount_minor))
);

create index if not exists chapa_refund_operations_payment_created_idx
  on public.chapa_refund_operations(payment_id, created_at desc);
create index if not exists chapa_refund_operations_status_created_idx
  on public.chapa_refund_operations(status, created_at desc);

alter table public.chapa_refund_operations enable row level security;
revoke all on public.chapa_refund_operations from anon, authenticated;
grant all on public.chapa_refund_operations to service_role;

create or replace function public.prepare_chapa_refund(
  p_payment_id uuid,
  p_amount_minor bigint,
  p_reason text,
  p_idempotency_key text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_payment public.payments%rowtype;
  v_existing public.chapa_refund_operations%rowtype;
  v_reserved bigint := 0;
  v_amount bigint;
  v_full boolean;
  v_reference text;
  v_operation public.chapa_refund_operations%rowtype;
begin
  if auth.uid() is null or not public.is_tiqet_admin() then
    raise exception 'Tiqet administrator permission required';
  end if;
  if p_payment_id is null or p_idempotency_key is null or
     p_idempotency_key !~ '^[0-9a-fA-F-]{36}$' then
    raise exception 'Invalid payment or idempotency key';
  end if;
  if p_reason is null or char_length(btrim(p_reason)) not between 1 and 400 then
    raise exception 'Refund reason must contain 1 to 400 characters';
  end if;

  select * into v_existing from public.chapa_refund_operations
    where idempotency_key = p_idempotency_key for update;
  if found then
    if v_existing.payment_id <> p_payment_id or v_existing.reason <> btrim(p_reason) or
       v_existing.requested_amount_minor is distinct from p_amount_minor then
      raise exception 'Idempotency key was already used for a different refund request';
    end if;
    return jsonb_build_object('operation', to_jsonb(v_existing), 'replayed', true);
  end if;

  select * into v_payment from public.payments where id = p_payment_id for update;
  if not found then raise exception 'Payment record not found'; end if;
  if v_payment.provider <> 'chapa' then raise exception 'Only Chapa payments can be refunded here'; end if;
  if v_payment.status <> 'succeeded' then
    raise exception 'Payment must be successfully verified and not already under review or refunded';
  end if;
  if coalesce(v_payment.provider_reference, '') = '' then
    raise exception 'Verified Chapa payment reference is missing';
  end if;

  select coalesce(sum(amount_minor),0)::bigint into v_reserved
    from public.chapa_refund_operations
    where payment_id = p_payment_id and status in ('requested','pending','submission_unknown','review');

  if p_amount_minor is null then
    if coalesce(v_payment.refunded_amount_minor,0) > 0 or v_reserved > 0 then
      raise exception 'A full refund can only be requested before any partial or pending refund';
    end if;
    v_amount := v_payment.amount_minor;
    v_full := true;
  else
    if p_amount_minor < 100 then raise exception 'Partial refund minimum is ETB 1.00'; end if;
    v_amount := p_amount_minor;
    v_full := false;
  end if;

  if coalesce(v_payment.refunded_amount_minor,0) + v_reserved + v_amount > v_payment.amount_minor then
    raise exception 'Refund amount exceeds the remaining paid amount';
  end if;
  if v_full and (coalesce(v_payment.refunded_amount_minor,0) <> 0 or v_reserved <> 0) then
    raise exception 'Full refund is unavailable after another refund request';
  end if;

  v_reference := 'TQRF' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,16));
  insert into public.chapa_refund_operations(
    payment_id, order_id, merchant_reference, idempotency_key,
    requested_amount_minor, amount_minor, request_full_refund,
    reason, requested_by
  ) values (
    v_payment.id, v_payment.order_id, v_reference, p_idempotency_key,
    p_amount_minor, v_amount, v_full, btrim(p_reason), auth.uid()
  ) returning * into v_operation;

  return jsonb_build_object('operation', to_jsonb(v_operation), 'replayed', false);
end;
$function$;

create or replace function public.record_chapa_refund_result(
  p_refund_id uuid,
  p_status text,
  p_provider_reference text,
  p_provider_payload jsonb default '{}'::jsonb,
  p_error_message text default null
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_operation public.chapa_refund_operations%rowtype;
  v_payment public.payments%rowtype;
  v_new_refunded bigint;
  v_status text := lower(coalesce(p_status,''));
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role' then
    raise exception 'Service role required';
  end if;
  if p_refund_id is null or v_status not in ('pending','submission_unknown','succeeded','failed','review') then
    raise exception 'Invalid refund result';
  end if;

  select * into v_operation from public.chapa_refund_operations
    where id = p_refund_id for update;
  if not found then raise exception 'Refund operation not found'; end if;
  select * into v_payment from public.payments where id = v_operation.payment_id for update;
  if not found then raise exception 'Payment record not found'; end if;

  if v_operation.status = 'succeeded' and v_status <> 'succeeded' then
    return jsonb_build_object('operation',to_jsonb(v_operation),'ignored_regression',true);
  end if;

  if v_status = 'succeeded' and v_operation.status <> 'succeeded' then
    v_new_refunded := coalesce(v_payment.refunded_amount_minor,0) + v_operation.amount_minor;
    if v_new_refunded > v_payment.amount_minor then
      update public.chapa_refund_operations set status='review',
        error_message='Verified refund would exceed the original payment amount.',
        provider_reference=coalesce(p_provider_reference,provider_reference),
        provider_payload=coalesce(p_provider_payload,'{}'::jsonb), updated_at=now()
        where id=p_refund_id returning * into v_operation;
      return jsonb_build_object('operation',to_jsonb(v_operation),'requires_manual_review',true);
    end if;
    update public.payments set refunded_amount_minor=v_new_refunded,
      status=case when v_new_refunded >= amount_minor then 'refunded' else 'succeeded' end,
      updated_at=now()
      where id=v_payment.id;
    update public.orders set status='payment_review',updated_at=now()
      where id=v_payment.order_id and status in ('paid','payment_review');
  end if;

  update public.chapa_refund_operations set
    status=v_status,
    provider_reference=coalesce(nullif(p_provider_reference,''),provider_reference),
    provider_payload=coalesce(p_provider_payload,'{}'::jsonb),
    error_message=case when v_status in ('failed','submission_unknown','review')
      then nullif(left(coalesce(p_error_message,''),500),'') else null end,
    verified_at=case when v_status in ('succeeded','failed') then now() else verified_at end,
    updated_at=now()
  where id=p_refund_id returning * into v_operation;

  return jsonb_build_object('operation',to_jsonb(v_operation),'requires_manual_review',v_status='review');
end;
$function$;

create or replace function public.get_tiqet_refunds_dashboard(p_limit integer default 50)
returns jsonb
language plpgsql
security definer
set search_path = ''
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
    'summary', jsonb_build_object(
      'open',(select count(*) from public.chapa_refund_operations where status in ('requested','pending','submission_unknown','review')),
      'succeeded',(select count(*) from public.chapa_refund_operations where status='succeeded'),
      'failed',(select count(*) from public.chapa_refund_operations where status='failed')
    ),
    'refunds',coalesce((
      select jsonb_agg(x.item order by x.created_at desc)
      from (
        select jsonb_build_object(
          'id',r.id,'payment_id',r.payment_id,'order_id',r.order_id,
          'merchant_reference',r.merchant_reference,
          'provider_reference',r.provider_reference,
          'idempotency_key',r.idempotency_key,
          'requested_amount_minor',r.requested_amount_minor,
          'amount_minor',r.amount_minor,
          'request_full_refund',r.request_full_refund,
          'reason',r.reason,'status',r.status,'error_message',r.error_message,
          'payment_merchant_reference',p.merchant_reference,
          'created_at',r.created_at,'updated_at',r.updated_at,'verified_at',r.verified_at
        ) item,r.created_at
        from public.chapa_refund_operations r
        join public.payments p on p.id=r.payment_id
        order by r.created_at desc limit p_limit
      ) x
    ),'[]'::jsonb)
  ) into v_result;
  return v_result;
end;
$function$;


-- Reconcile cumulative refund webhook totals without treating the payment reference
-- in a refund webhook as an individual refund reference.
create or replace function public.reconcile_chapa_refund_notice(
  p_merchant_reference text,
  p_refunded_amount_minor bigint
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_payment public.payments%rowtype;
  v_verified_total bigint := 0;
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role' then
    raise exception 'Service role required';
  end if;
  if p_merchant_reference is null or btrim(p_merchant_reference) = '' or
     p_refunded_amount_minor is null or p_refunded_amount_minor <= 0 then
    raise exception 'Invalid refund reconciliation input';
  end if;

  select * into v_payment
    from public.payments
    where merchant_reference = p_merchant_reference
    for update;
  if not found then raise exception 'Payment reference not found'; end if;
  if p_refunded_amount_minor > v_payment.amount_minor then
    raise exception 'Webhook refund total exceeds the original payment amount';
  end if;

  select coalesce(sum(amount_minor), 0)::bigint into v_verified_total
    from public.chapa_refund_operations
    where payment_id = v_payment.id and status = 'succeeded';

  -- A mismatch can indicate an external/manual refund, an unverified operation,
  -- or an out-of-order notification. Keep the payment in review in those cases.
  if v_verified_total <> p_refunded_amount_minor then
    return jsonb_build_object(
      'reconciled', false,
      'verified_ledger_amount_minor', v_verified_total,
      'webhook_refunded_amount_minor', p_refunded_amount_minor,
      'manual_review_required', true
    );
  end if;

  update public.payments
    set refunded_amount_minor = v_verified_total,
        status = case when v_verified_total >= amount_minor then 'refunded' else 'succeeded' end,
        updated_at = now()
    where id = v_payment.id;

  return jsonb_build_object(
    'reconciled', true,
    'refunded_amount_minor', v_verified_total,
    'payment_status', case when v_verified_total >= v_payment.amount_minor then 'refunded' else 'succeeded' end
  );
end;
$function$;

revoke all on function public.prepare_chapa_refund(uuid,bigint,text,text) from public, anon;
grant execute on function public.prepare_chapa_refund(uuid,bigint,text,text) to authenticated;
revoke all on function public.record_chapa_refund_result(uuid,text,text,jsonb,text) from public, anon, authenticated;
grant execute on function public.record_chapa_refund_result(uuid,text,text,jsonb,text) to service_role;
revoke all on function public.get_tiqet_refunds_dashboard(integer) from public, anon;
grant execute on function public.get_tiqet_refunds_dashboard(integer) to authenticated;
revoke all on function public.reconcile_chapa_refund_notice(text,bigint) from public, anon, authenticated;
grant execute on function public.reconcile_chapa_refund_notice(text,bigint) to service_role;

commit;
