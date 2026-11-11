insert into public.organiser_payout_requests(
  id, organisation_id, requested_by, provider, amount_minor, idempotency_key
) values (
  '10000000-0000-4000-8000-000000000001',
  '20000000-0000-4000-8000-000000000001',
  '30000000-0000-4000-8000-000000000001',
  'chapa', 2500, 'test-payout-001'
);

set request.jwt.claims = '{"role":"service_role"}';
set role service_role;

do $$
declare v jsonb;
begin
  begin
    perform public.resolve_organiser_payout_request(
      '10000000-0000-4000-8000-000000000001','paid','PROVIDER-REF-001',
      'Attempt to skip approval and processing',
      '30000000-0000-4000-8000-000000000001'
    );
    raise exception 'Expected invalid requested -> paid transition to be rejected';
  exception when others then
    if sqlerrm not like 'Invalid organiser payout transition:%' then raise; end if;
  end;

  v := public.resolve_organiser_payout_request(
    '10000000-0000-4000-8000-000000000001','approved',null,'Reviewed and approved',
    '30000000-0000-4000-8000-000000000001'
  );
  if v->>'status' <> 'approved' then raise exception 'Approval transition failed'; end if;

  perform public.resolve_organiser_payout_request(
    '10000000-0000-4000-8000-000000000001','processing',null,'Transfer is being processed',
    '30000000-0000-4000-8000-000000000001'
  );
  perform public.resolve_organiser_payout_request(
    '10000000-0000-4000-8000-000000000001','paid','BANK-TRANSFER-001','Bank transfer independently confirmed',
    '30000000-0000-4000-8000-000000000001'
  );
  if (select count(*) from public.organiser_settlement_ledger where entry_type='payout_debit') <> 1 then
    raise exception 'Paid transition did not create exactly one settlement debit';
  end if;
  perform public.resolve_organiser_payout_request(
    '10000000-0000-4000-8000-000000000001','reversed','BANK-REVERSAL-001','Bank reversal independently confirmed',
    '30000000-0000-4000-8000-000000000001'
  );
  if (select count(*) from public.organiser_settlement_ledger where entry_type='payout_reversal') <> 1 then
    raise exception 'Reversal transition did not create exactly one settlement reversal';
  end if;
  if (select count(*) from public.organiser_settlement_ledger) <> 2 then
    raise exception 'Unexpected settlement ledger row count';
  end if;
  if (select reviewed_by from public.organiser_payout_requests where id='10000000-0000-4000-8000-000000000001')
      <> '30000000-0000-4000-8000-000000000001'::uuid then
    raise exception 'Acting administrator was not recorded';
  end if;
end;
$$;
reset role;
