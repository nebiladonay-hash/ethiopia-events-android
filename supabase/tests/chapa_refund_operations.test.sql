BEGIN;

DO $$
DECLARE
  v_order uuid;
  v_payment uuid;
  v_second_order uuid;
  v_second_payment uuid;
  v_result jsonb;
  v_replay jsonb;
  v_dashboard jsonb;
  v_refund_id uuid;
  v_second_refund_id uuid;
  v_full_refund_id uuid;
  v_error text;
  v_count bigint;
  v_payout_id uuid;
  v_payout_result jsonb;
BEGIN
  -- The RPC must reject callers without an authenticated administrator identity.
  PERFORM set_config('request.jwt.claim.sub', '', true);
  PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
  BEGIN
    PERFORM public.prepare_chapa_refund(
      gen_random_uuid(), 100, 'unauthenticated attempt',
      '10000000-0000-4000-8000-000000000001'
    );
    RAISE EXCEPTION 'TEST_ASSERT: unauthenticated prepare unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
    IF v_error LIKE 'TEST_ASSERT:%' THEN RAISE; END IF;
    IF v_error NOT LIKE '%Tiqet administrator permission required%' THEN
      RAISE EXCEPTION 'Unexpected unauthenticated error: %', v_error;
    END IF;
  END;

  PERFORM set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', true);
  PERFORM set_config('request.jwt.claim.role', 'authenticated', true);

  INSERT INTO public.orders(status) VALUES ('paid') RETURNING id INTO v_order;
  INSERT INTO public.payments(
    order_id, provider, merchant_reference, provider_reference,
    amount_minor, currency, status
  ) VALUES (
    v_order, 'chapa', 'TQ-PAY-REFUND-TEST-1', 'CHAPA-PAY-REF-1',
    1000, 'ETB', 'succeeded'
  ) RETURNING id INTO v_payment;

  -- First partial request reserves 400 minor units.
  v_result := public.prepare_chapa_refund(
    v_payment, 400, 'Customer requested partial refund',
    '10000000-0000-4000-8000-000000000002'
  );
  v_refund_id := (v_result->'operation'->>'id')::uuid;
  IF (v_result->'operation'->>'amount_minor')::bigint <> 400 THEN
    RAISE EXCEPTION 'TEST_ASSERT: partial amount was not persisted';
  END IF;
  IF (v_result->'operation'->>'request_full_refund')::boolean THEN
    RAISE EXCEPTION 'TEST_ASSERT: partial request was marked as full';
  END IF;

  -- Same key and same request must replay the same operation.
  v_replay := public.prepare_chapa_refund(
    v_payment, 400, 'Customer requested partial refund',
    '10000000-0000-4000-8000-000000000002'
  );
  IF (v_replay->>'replayed')::boolean IS NOT TRUE
     OR (v_replay->'operation'->>'id')::uuid <> v_refund_id THEN
    RAISE EXCEPTION 'TEST_ASSERT: idempotent replay did not return the original refund';
  END IF;

  -- Reusing the key for a different reason must be rejected.
  BEGIN
    PERFORM public.prepare_chapa_refund(
      v_payment, 400, 'Different reason',
      '10000000-0000-4000-8000-000000000002'
    );
    RAISE EXCEPTION 'TEST_ASSERT: mismatched idempotency replay unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
    IF v_error LIKE 'TEST_ASSERT:%' THEN RAISE; END IF;
    IF v_error NOT LIKE '%Idempotency key was already used%' THEN
      RAISE EXCEPTION 'Unexpected idempotency error: %', v_error;
    END IF;
  END;

  -- The outstanding 400 reservation means another 700 would over-refund.
  BEGIN
    PERFORM public.prepare_chapa_refund(
      v_payment, 700, 'Excess refund attempt',
      '10000000-0000-4000-8000-000000000003'
    );
    RAISE EXCEPTION 'TEST_ASSERT: over-refund unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
    IF v_error LIKE 'TEST_ASSERT:%' THEN RAISE; END IF;
    IF v_error NOT LIKE '%Refund amount exceeds the remaining paid amount%' THEN
      RAISE EXCEPTION 'Unexpected over-refund error: %', v_error;
    END IF;
  END;

  -- A full refund cannot be opened while a partial request remains unresolved.
  BEGIN
    PERFORM public.prepare_chapa_refund(
      v_payment, NULL, 'Full refund while partial is pending',
      '10000000-0000-4000-8000-000000000004'
    );
    RAISE EXCEPTION 'TEST_ASSERT: conflicting full refund unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
    IF v_error LIKE 'TEST_ASSERT:%' THEN RAISE; END IF;
    IF v_error NOT LIKE '%full refund can only be requested%' THEN
      RAISE EXCEPTION 'Unexpected full-refund reservation error: %', v_error;
    END IF;
  END;

  -- The result recorder must reject a caller whose JWT role is not service_role.
  BEGIN
    PERFORM public.record_chapa_refund_result(
      v_refund_id, 'pending', 'CHAPA-REFUND-1', '{}'::jsonb, NULL
    );
    RAISE EXCEPTION 'TEST_ASSERT: authenticated caller wrote provider result';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
    IF v_error LIKE 'TEST_ASSERT:%' THEN RAISE; END IF;
    IF v_error NOT LIKE '%Service role required%' THEN
      RAISE EXCEPTION 'Unexpected service-role gate error: %', v_error;
    END IF;
  END;

  -- A verified partial refund updates refunded totals and moves the order to review.
  PERFORM set_config('request.jwt.claim.role', 'service_role', true);
  PERFORM public.record_chapa_refund_result(
    v_refund_id, 'succeeded', 'CHAPA-REFUND-1',
    '{"status":"success","data":{"status":"SUCCESS"}}'::jsonb, NULL
  );

  IF (SELECT refunded_amount_minor FROM public.payments WHERE id = v_payment) <> 400 THEN
    RAISE EXCEPTION 'TEST_ASSERT: partial refund total was not updated';
  END IF;
  IF (SELECT status FROM public.orders WHERE id = v_order) <> 'payment_review' THEN
    RAISE EXCEPTION 'TEST_ASSERT: order was not moved to payment_review';
  END IF;
  IF (SELECT status FROM public.payments WHERE id = v_payment) <> 'succeeded' THEN
    RAISE EXCEPTION 'TEST_ASSERT: partially refunded payment should remain succeeded';
  END IF;

  -- A late refund webhook first marks the payment for review. It may restore the
  -- partial-refund state only when cumulative webhook totals match verified rows.
  UPDATE public.payments SET status = 'review' WHERE id = v_payment;
  v_result := public.reconcile_chapa_refund_notice('TQ-PAY-REFUND-TEST-1', 400);
  IF coalesce((v_result->>'reconciled')::boolean, false) IS NOT TRUE
     OR (SELECT status FROM public.payments WHERE id = v_payment) <> 'succeeded' THEN
    RAISE EXCEPTION 'TEST_ASSERT: matching late webhook did not reconcile verified partial refund';
  END IF;

  -- A separate unmatched webhook must remain in manual review.
  INSERT INTO public.orders(status) VALUES ('paid') RETURNING id INTO v_second_order;
  INSERT INTO public.payments(
    order_id, provider, merchant_reference, provider_reference,
    amount_minor, currency, status
  ) VALUES (
    v_second_order, 'chapa', 'TQ-PAY-REFUND-UNMATCHED', 'CHAPA-PAY-REF-UNMATCHED',
    1000, 'ETB', 'succeeded'
  ) RETURNING id INTO v_second_payment;
  UPDATE public.payments SET status = 'review' WHERE id = v_second_payment;
  v_result := public.reconcile_chapa_refund_notice('TQ-PAY-REFUND-UNMATCHED', 100);
  IF coalesce((v_result->>'reconciled')::boolean, false) IS TRUE
     OR (SELECT status FROM public.payments WHERE id = v_second_payment) <> 'review' THEN
    RAISE EXCEPTION 'TEST_ASSERT: unmatched webhook did not remain in review';
  END IF;

  -- A second partial refund may consume only the remaining 600 units.
  PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
  v_result := public.prepare_chapa_refund(
    v_payment, 600, 'Refund remaining paid balance',
    '10000000-0000-4000-8000-000000000005'
  );
  v_second_refund_id := (v_result->'operation'->>'id')::uuid;

  PERFORM set_config('request.jwt.claim.role', 'service_role', true);
  PERFORM public.record_chapa_refund_result(
    v_second_refund_id, 'succeeded', 'CHAPA-REFUND-2',
    '{"status":"success","data":{"status":"SUCCESS"}}'::jsonb, NULL
  );
  IF (SELECT refunded_amount_minor FROM public.payments WHERE id = v_payment) <> 1000 THEN
    RAISE EXCEPTION 'TEST_ASSERT: combined partial refunds did not total the paid amount';
  END IF;
  IF (SELECT status FROM public.payments WHERE id = v_payment) <> 'refunded' THEN
    RAISE EXCEPTION 'TEST_ASSERT: fully refunded payment status was not updated';
  END IF;

  -- A later failed status must not regress a previously verified success.
  v_result := public.record_chapa_refund_result(
    v_second_refund_id, 'failed', 'CHAPA-REFUND-2',
    '{"status":"success","data":{"status":"FAILED"}}'::jsonb,
    'Late contradictory failure'
  );
  IF coalesce((v_result->>'ignored_regression')::boolean, false) IS NOT TRUE THEN
    RAISE EXCEPTION 'TEST_ASSERT: succeeded refund accepted a status regression';
  END IF;
  IF (SELECT refunded_amount_minor FROM public.payments WHERE id = v_payment) <> 1000 THEN
    RAISE EXCEPTION 'TEST_ASSERT: status regression changed refunded total';
  END IF;

  -- Refunded payments cannot receive another refund reservation.
  PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
  BEGIN
    PERFORM public.prepare_chapa_refund(
      v_payment, 100, 'Attempt after full refund',
      '10000000-0000-4000-8000-000000000006'
    );
    RAISE EXCEPTION 'TEST_ASSERT: refund after full refund unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
    IF v_error LIKE 'TEST_ASSERT:%' THEN RAISE; END IF;
    IF v_error NOT LIKE '%Payment must be successfully verified%' THEN
      RAISE EXCEPTION 'Unexpected post-refund rejection: %', v_error;
    END IF;
  END;

  -- Explicit full-refund request omits the amount but reserves the exact paid amount.
  INSERT INTO public.orders(status) VALUES ('paid') RETURNING id INTO v_order;
  INSERT INTO public.payments(
    order_id, provider, merchant_reference, provider_reference,
    amount_minor, currency, status
  ) VALUES (
    v_order, 'chapa', 'TQ-PAY-REFUND-TEST-2', 'CHAPA-PAY-REF-2',
    800, 'ETB', 'succeeded'
  ) RETURNING id INTO v_second_payment;

  v_result := public.prepare_chapa_refund(
    v_second_payment, NULL, 'Customer requested full refund',
    '10000000-0000-4000-8000-000000000007'
  );
  v_full_refund_id := (v_result->'operation'->>'id')::uuid;
  IF (v_result->'operation'->>'amount_minor')::bigint <> 800
     OR (v_result->'operation'->>'request_full_refund')::boolean IS NOT TRUE
     OR (v_result->'operation'->>'requested_amount_minor') IS NOT NULL THEN
    RAISE EXCEPTION 'TEST_ASSERT: full refund amount/marker was not persisted correctly';
  END IF;

  PERFORM set_config('request.jwt.claim.role', 'service_role', true);
  PERFORM public.record_chapa_refund_result(
    v_full_refund_id, 'succeeded', 'CHAPA-REFUND-3',
    '{"status":"success","data":{"status":"SUCCESS"}}'::jsonb, NULL
  );
  IF (SELECT refunded_amount_minor FROM public.payments WHERE id = v_second_payment) <> 800
     OR (SELECT status FROM public.payments WHERE id = v_second_payment) <> 'refunded' THEN
    RAISE EXCEPTION 'TEST_ASSERT: full refund did not mark payment refunded';
  END IF;

  -- Admin dashboard returns the complete operation count.
  PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
  v_dashboard := public.get_tiqet_refunds_dashboard(10);
  IF (v_dashboard->'summary'->>'succeeded')::integer <> 3 THEN
    RAISE EXCEPTION 'TEST_ASSERT: dashboard succeeded count is incorrect: %', v_dashboard;
  END IF;
  SELECT count(*) INTO v_count
  FROM jsonb_array_elements(v_dashboard->'refunds');
  IF v_count <> 3 THEN
    RAISE EXCEPTION 'TEST_ASSERT: dashboard refund rows are incomplete';
  END IF;

  -- Payout result writes are service-role-only.
  INSERT INTO public.platform_payouts(
    amount_minor, currency, bank_slug, bank_name, account_name,
    account_last4, merchant_reference
  ) VALUES (
    25000, 'ETB', 'test_bank', 'Test Bank', 'Test Account',
    '1234', 'TQ-PAYOUT-STATE-TEST'
  ) RETURNING id INTO v_payout_id;

  PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
  BEGIN
    PERFORM public.record_tiqet_platform_payout_result(
      v_payout_id, 'pending', 'CHAPA-PAYOUT-STATE-1', 0, '{}'::jsonb
    );
    RAISE EXCEPTION 'TEST_ASSERT: authenticated caller wrote payout provider result';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
    IF v_error LIKE 'TEST_ASSERT:%' THEN RAISE; END IF;
    IF v_error NOT LIKE '%Service role required%' THEN
      RAISE EXCEPTION 'Unexpected payout service-role gate error: %', v_error;
    END IF;
  END;

  PERFORM set_config('request.jwt.claim.role', 'service_role', true);
  v_payout_result := public.record_tiqet_platform_payout_result(
    v_payout_id, 'succeeded', 'CHAPA-PAYOUT-STATE-1', 250, '{"status":"SUCCESS"}'::jsonb
  );
  IF v_payout_result->>'status' <> 'succeeded' THEN
    RAISE EXCEPTION 'TEST_ASSERT: verified payout success was not recorded';
  END IF;

  -- A late PENDING or FAILED notification cannot regress a terminal success.
  v_payout_result := public.record_tiqet_platform_payout_result(
    v_payout_id, 'pending', 'CHAPA-PAYOUT-STATE-1', 0, '{"status":"PENDING"}'::jsonb
  );
  IF coalesce((v_payout_result->>'ignored_conflicting_status')::boolean, false) IS NOT TRUE
     OR (SELECT status FROM public.platform_payouts WHERE id = v_payout_id) <> 'succeeded' THEN
    RAISE EXCEPTION 'TEST_ASSERT: stale pending payout status regressed success';
  END IF;

  v_payout_result := public.record_tiqet_platform_payout_result(
    v_payout_id, 'failed', 'CHAPA-PAYOUT-STATE-1', 0, '{"status":"FAILED"}'::jsonb
  );
  IF coalesce((v_payout_result->>'ignored_conflicting_status')::boolean, false) IS NOT TRUE
     OR (SELECT status FROM public.platform_payouts WHERE id = v_payout_id) <> 'succeeded' THEN
    RAISE EXCEPTION 'TEST_ASSERT: contradictory payout failure regressed success';
  END IF;

  -- A verified reversal is the one supported terminal transition after success.
  v_payout_result := public.record_tiqet_platform_payout_result(
    v_payout_id, 'reversed', 'CHAPA-PAYOUT-STATE-1', 250, '{"status":"REVERSED"}'::jsonb
  );
  IF coalesce((v_payout_result->>'ignored_conflicting_status')::boolean, false) IS TRUE
     OR (SELECT status FROM public.platform_payouts WHERE id = v_payout_id) <> 'reversed' THEN
    RAISE EXCEPTION 'TEST_ASSERT: verified payout reversal was not recorded';
  END IF;

  v_payout_result := public.record_tiqet_platform_payout_result(
    v_payout_id, 'succeeded', 'CHAPA-PAYOUT-STATE-1', 250, '{"status":"SUCCESS"}'::jsonb
  );
  IF coalesce((v_payout_result->>'ignored_conflicting_status')::boolean, false) IS NOT TRUE
     OR (SELECT status FROM public.platform_payouts WHERE id = v_payout_id) <> 'reversed' THEN
    RAISE EXCEPTION 'TEST_ASSERT: late success regressed a verified payout reversal';
  END IF;

  RAISE NOTICE 'PASS: refund and payout reconciliation lifecycle tests completed';
END $$;

ROLLBACK;
