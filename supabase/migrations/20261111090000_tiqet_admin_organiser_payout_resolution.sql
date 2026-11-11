-- Make the organiser payout resolution RPC reproducible and enforce
-- the complete state machine inside the row-locked database transaction.

begin;

drop function if exists public.resolve_organiser_payout_request(uuid,text,text,text);

create function public.resolve_organiser_payout_request(
  p_request_id uuid,
  p_status text,
  p_provider_reference text default null,
  p_operator_note text default null,
  p_actor_user_id uuid default null
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_row public.organiser_payout_requests%rowtype;
  v_reference text := nullif(btrim(p_provider_reference), '');
  v_note text := nullif(btrim(p_operator_note), '');
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role' then
    raise exception 'Service role required';
  end if;
  if p_request_id is null or p_actor_user_id is null then
    raise exception 'Payout request and acting administrator are required';
  end if;
  if p_status not in ('approved','processing','paid','rejected','failed','reversed') then
    raise exception 'Invalid payout status';
  end if;
  if v_note is null or char_length(v_note) not between 5 and 500 then
    raise exception 'Operator note must contain 5 to 500 characters';
  end if;
  if p_status in ('paid','reversed') and (v_reference is null or char_length(v_reference) < 3) then
    raise exception 'Provider reference is required to confirm payment or reversal';
  end if;

  select * into v_row
  from public.organiser_payout_requests
  where id = p_request_id
  for update;
  if not found then raise exception 'Payout request not found'; end if;

  if not (
    (v_row.status = 'requested' and p_status in ('approved','rejected')) or
    (v_row.status = 'approved' and p_status in ('processing','rejected','failed')) or
    (v_row.status = 'processing' and p_status in ('paid','failed')) or
    (v_row.status = 'paid' and p_status = 'reversed')
  ) then
    raise exception 'Invalid organiser payout transition: % -> %', v_row.status, p_status;
  end if;

  update public.organiser_payout_requests
  set status = p_status,
      provider_reference = coalesce(v_reference, provider_reference),
      operator_note = v_note,
      reviewed_by = p_actor_user_id,
      reviewed_at = case when p_status in ('approved','rejected') then now() else reviewed_at end,
      completed_at = case when p_status in ('paid','failed','reversed') then now() else completed_at end,
      updated_at = now()
  where id = p_request_id;

  if p_status = 'paid' then
    insert into public.organiser_settlement_ledger(
      organisation_id, order_id, provider, entry_type, amount_minor,
      idempotency_key, reference, description
    ) values (
      v_row.organisation_id, null, v_row.provider, 'payout_debit', -v_row.amount_minor,
      'organiser-payout-debit:' || v_row.id::text, v_reference, 'Confirmed organiser payout'
    ) on conflict (idempotency_key) do nothing;
  elsif p_status = 'reversed' then
    insert into public.organiser_settlement_ledger(
      organisation_id, order_id, provider, entry_type, amount_minor,
      idempotency_key, reference, description
    ) values (
      v_row.organisation_id, null, v_row.provider, 'payout_reversal', v_row.amount_minor,
      'organiser-payout-reversal:' || v_row.id::text, v_reference, 'Confirmed organiser payout reversal'
    ) on conflict (idempotency_key) do nothing;
  end if;

  return jsonb_build_object(
    'request_id', p_request_id,
    'previous_status', v_row.status,
    'status', p_status,
    'ledger_updated', p_status in ('paid','reversed')
  );
end;
$function$;

revoke all on function public.resolve_organiser_payout_request(uuid,text,text,text,uuid) from public, anon, authenticated;
grant execute on function public.resolve_organiser_payout_request(uuid,text,text,text,uuid) to service_role;

commit;
