-- Tiqet Control: administrator-only read-only payment, refund and payout monitoring.

begin;

create or replace function public.get_tiqet_finance_dashboard(p_limit integer default 25)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v_result jsonb;
begin
  if auth.uid() is null or not public.is_tiqet_admin() then
    raise exception 'Tiqet administrator permission required';
  end if;
  if p_limit is null or p_limit not between 1 and 50 then
    raise exception 'Limit must be from 1 to 50';
  end if;

  select jsonb_build_object(
    'currency','ETB',
    'summary',jsonb_build_object(
      'paid_orders',(select count(*) from public.orders where status='paid'::public.order_status),
      'payment_reviews',(select count(*) from public.orders where status='payment_review'::public.order_status),
      'pending_payment_attempts',(select count(*) from public.payments where status in ('initiated','pending','review')),
      'refunds_needing_review',(select count(*) from public.payment_refund_alerts where review_status in ('manual_review','pending')),
      'gross_platform_revenue_etb',
        coalesce((select sum(platform_gross_revenue_etb) from public.platform_revenue_ledger),0)::numeric(14,2),
      'reconciled_platform_adjustments_etb',
        coalesce((select sum(amount_minor::numeric/100) from public.platform_financial_adjustments),0)::numeric(14,2),
      'net_platform_revenue_etb',
        greatest(0,
          coalesce((select sum(platform_gross_revenue_etb) from public.platform_revenue_ledger),0)
          + coalesce((select sum(amount_minor::numeric/100) from public.platform_financial_adjustments),0)
        )::numeric(14,2),
      'platform_payouts_in_flight',
        (select count(*) from public.platform_payouts where status in ('reserved','pending','blocked','auth_needed','otp_needed')),
      'organiser_payout_requests_open',
        (select count(*) from public.organiser_payout_requests where status in ('requested','approved','processing'))
    ),
    'recent_payments',coalesce((
      select jsonb_agg(x.item order by x.created_at desc)
      from (
        select jsonb_build_object(
          'payment_id',p.id,'order_id',p.order_id,'merchant_reference',p.merchant_reference,
          'provider',p.provider,'provider_reference',p.provider_reference,'payment_method',p.payment_method,
          'status',p.status,'amount_minor',p.amount_minor,
          'amount_etb',round(p.amount_minor::numeric/100,2),'currency',p.currency,
          'created_at',p.created_at,'verified_at',p.verified_at,'last_verified_at',p.last_verified_at,
          'order_status',o.status::text,'buyer_email',u.email
        ) item,p.created_at
        from public.payments p
        join public.orders o on o.id=p.order_id
        left join auth.users u on u.id=o.buyer_id
        order by p.created_at desc limit p_limit
      ) x
    ),'[]'::jsonb),
    'refund_alerts',coalesce((
      select jsonb_agg(x.item order by x.received_at desc)
      from (
        select jsonb_build_object(
          'id',r.id,'merchant_reference',r.merchant_reference,'provider',p.provider,
          'event_name',r.event_name,'provider_status',r.provider_status,'review_status',r.review_status,
          'original_amount_minor',r.original_amount_minor,'refunded_amount_minor',r.refunded_amount_minor,
          'currency',r.currency,'received_at',r.received_at,'reconciled_at',r.reconciled_at
        ) item,r.received_at
        from public.payment_refund_alerts r
        left join public.payments p on p.id=r.payment_id
        order by r.received_at desc limit p_limit
      ) x
    ),'[]'::jsonb),
    'platform_payouts',coalesce((
      select jsonb_agg(x.item order by x.created_at desc)
      from (
        select jsonb_build_object(
          'id',p.id,'amount_minor',p.amount_minor,'amount_etb',round(p.amount_minor::numeric/100,2),
          'currency',p.currency,'bank_name',p.bank_name,'account_last4',p.account_last4,
          'merchant_reference',p.merchant_reference,'provider_reference',p.provider_reference,
          'status',p.status,'service_fee_minor',p.provider_service_fee_minor,
          'created_at',p.created_at,'updated_at',p.updated_at
        ) item,p.created_at
        from public.platform_payouts p
        order by p.created_at desc limit p_limit
      ) x
    ),'[]'::jsonb),
    'organiser_payout_requests',coalesce((
      select jsonb_agg(x.item order by x.created_at desc)
      from (
        select jsonb_build_object(
          'id',r.id,'organisation_id',r.organisation_id,'organisation_name',o.name,
          'provider',r.provider,'amount_minor',r.amount_minor,
          'amount_etb',round(r.amount_minor::numeric/100,2),
          'currency',r.currency,'status',r.status,'provider_reference',r.provider_reference,
          'operator_note',r.operator_note,'created_at',r.created_at,'updated_at',r.updated_at
        ) item,r.created_at
        from public.organiser_payout_requests r
        join public.organisations o on o.id=r.organisation_id
        order by r.created_at desc limit p_limit
      ) x
    ),'[]'::jsonb)
  ) into v_result;
  return v_result;
end;
$$;

revoke all on function public.get_tiqet_finance_dashboard(integer) from public,anon;
grant execute on function public.get_tiqet_finance_dashboard(integer) to authenticated,service_role;

commit;
