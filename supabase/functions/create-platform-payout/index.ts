import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.49.1'
const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}
function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
}
Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405)
  const authHeader = req.headers.get('Authorization')
  if (!authHeader?.startsWith('Bearer ')) return json({ error: 'Sign-in required' }, 401)
  const chapaKey = Deno.env.get('CHAPA_PRIVATE_KEY')
  const chapaMode = Deno.env.get('CHAPA_MODE')?.toLowerCase()
  if (!chapaKey || !['test', 'live'].includes(chapaMode ?? '')) return json({ error: 'Configure CHAPA_PRIVATE_KEY and CHAPA_MODE (test or live) in Supabase Edge Function secrets' }, 503)
  const keyMode = chapaKey.startsWith('CHAPA_TEST_') ? 'test' : chapaKey.startsWith('CHAPA_LIVE_') ? 'live' : null
  if (keyMode && keyMode !== chapaMode) return json({ error: 'Chapa API key environment does not match CHAPA_MODE' }, 503)
  if (chapaMode === 'live' && Deno.env.get('TIQET_LIVE_PAYOUTS_ENABLED') !== 'true') {
    return json({ error: 'Live platform withdrawals are locked until Tiqet and Chapa have approved the marketplace payout flow.' }, 403)
  }
  const url = Deno.env.get('SUPABASE_URL')!
  const anon = Deno.env.get('SUPABASE_ANON_KEY')!
  const service = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
  const userClient = createClient(url, anon, { global: { headers: { Authorization: authHeader } }, auth: { persistSession: false } })
  const admin = createClient(url, service, { auth: { persistSession: false } })
  const { data: auth, error: authError } = await userClient.auth.getUser()
  if (authError || !auth.user) return json({ error: 'Invalid or expired session' }, 401)
  if (auth.user.app_metadata?.tiqet_role !== 'platform_owner') return json({ error: 'Platform-owner access required' }, 403)
  let body: { amount_etb?: number; bank_slug?: string; bank_name?: string; account_name?: string; account_number?: string }
  try { body = await req.json() } catch { return json({ error: 'Invalid JSON body' }, 400) }
  const amount = Number(body.amount_etb)
  const accountName = body.account_name?.trim() ?? ''
  const accountNumber = body.account_number?.trim().replace(/\s+/g, '') ?? ''
  const bankSlug = body.bank_slug?.trim().toLowerCase() ?? ''
  if (!Number.isFinite(amount) || amount <= 0 || amount > 100000000 || !accountName || !/^\d{6,30}$/.test(accountNumber) || !bankSlug) {
    return json({ error: 'Enter a valid amount, destination bank or wallet, account name, and account number' }, 400)
  }
  const amountMinor = Math.round(amount * 100)
  if (amountMinor < 100) return json({ error: 'Minimum withdrawal is ETB 1.00' }, 400)

  let banksResponse: Response
  let banksJson: Record<string, any>
  try {
    banksResponse = await fetch('https://api.chapa.global/v2/payouts/banks?country=ET', { headers: { Authorization: `Bearer ${chapaKey}` } })
    banksJson = await banksResponse.json().catch(() => ({}))
  } catch {
    return json({ error: 'Could not reach Chapa to validate payout destinations. No withdrawal was reserved.' }, 503)
  }
  const bank = Array.isArray(banksJson?.data) ? banksJson.data.find((b: Record<string, any>) => b.bank_slug === bankSlug && b.is_active === true) : null
  if (!banksResponse.ok || !bank) return json({ error: 'That payout destination is not currently enabled by Chapa' }, 400)
  const min = Number(bank.min_amount ?? 100)
  const max = Number(bank.max_amount ?? 100000000)
  if (amountMinor < min || amountMinor > max) return json({ error: `This destination supports withdrawals between ETB ${(min/100).toFixed(2)} and ETB ${(max/100).toFixed(2)}` }, 400)

  let balanceResponse: Response
  let balanceJson: Record<string, any>
  try {
    balanceResponse = await fetch('https://api.chapa.global/v2/balances?currency=ETB', { headers: { Authorization: `Bearer ${chapaKey}` } })
    balanceJson = await balanceResponse.json().catch(() => ({}))
  } catch {
    return json({ error: 'Could not reach Chapa to verify available balance. No withdrawal was reserved.' }, 503)
  }
  const availableBalanceMinor = Number(balanceJson?.data?.available_balance?.ETB)
  if (!balanceResponse.ok || balanceJson?.status !== 'success' ||
      !Number.isSafeInteger(availableBalanceMinor) || availableBalanceMinor < 0) {
    return json({ error: 'Could not verify Chapa available balance. No withdrawal was reserved.' }, 503)
  }

  const { data: reservation, error: reserveError } = await admin.rpc('reserve_tiqet_platform_payout', {
    p_amount_minor: amountMinor, p_bank_slug: bankSlug,
    p_bank_name: bank.bank_name ?? body.bank_name ?? bankSlug,
    p_account_name: accountName, p_account_number: accountNumber,
    p_chapa_available_balance_minor: availableBalanceMinor,
  })
  if (reserveError || !reservation?.id || !reservation?.merchant_reference) {
    return json({ error: reserveError?.message ?? 'Could not reserve the requested amount' }, 409)
  }

  let response: Response
  let result: Record<string, any>
  try {
    response = await fetch('https://api.chapa.global/v2/payouts', {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${chapaKey}`, 'Content-Type': 'application/json',
        'Idempotency-Key': reservation.merchant_reference,
      },
      body: JSON.stringify({
        amount: amountMinor, currency: 'ETB', merchant_reference: reservation.merchant_reference,
        account: { account_number: accountNumber, account_name: accountName, bank_slug: bankSlug, bank_name: bank.bank_name ?? bankSlug },
        reason: 'Tiqet platform revenue withdrawal',
        meta: { app: 'tiqet', purpose: 'platform_revenue_cashout' },
      }),
    })
    result = await response.json().catch(() => ({}))
  } catch {
    const { data: uncertainResult, error: uncertainUpdateError } = await admin.rpc('record_tiqet_platform_payout_result', {
      p_payout_id: reservation.id,
      p_status: 'pending',
      p_provider_reference: null,
      p_provider_service_fee_minor: 0,
      p_provider_payload: { creation_status: 'unknown', creation_message: 'Network interruption during payout submission; provider acceptance is unknown.', ambiguous_provider_response: true },
    })
    if (uncertainUpdateError) {
      console.error('Could not persist uncertain Chapa payout submission', uncertainUpdateError.message)
      return json({ error: 'The payout submission result is unknown and its reconciliation record could not be saved. Do not submit another withdrawal; contact support.' }, 500)
    }
    return json({
      payout_id: reservation.id, merchant_reference: reservation.merchant_reference, status: uncertainResult?.status ?? 'pending',
      message: 'The payout submission result is unknown. The amount remains reserved for reconciliation. Do not submit another withdrawal.',
    }, 202)
  }

  const chapaReference = String(result?.data?.chapa_reference ?? '')
  if (!response.ok || result?.status !== 'success' || !chapaReference) {
    const definiteRejection = response.status >= 400 && response.status < 500 &&
      ![408, 409, 425, 429].includes(response.status)
    const { data: creationResult, error: creationUpdateError } = await admin.rpc('record_tiqet_platform_payout_result', {
      p_payout_id: reservation.id,
      p_status: definiteRejection ? 'failed' : 'pending',
      p_provider_reference: chapaReference || null,
      p_provider_service_fee_minor: 0,
      p_provider_payload: { creation_status: String(result?.status ?? 'unknown'), creation_message: String(result?.message ?? ''), ambiguous_provider_response: !definiteRejection },
    })
    if (creationUpdateError) {
      console.error('Could not persist Chapa payout creation result', creationUpdateError.message)
      return json({ error: 'Chapa payout response received but could not be safely persisted; reconcile this withdrawal before retrying.' }, 500)
    }
    if (definiteRejection && creationResult?.status === 'failed') return json({ error: result?.message ?? 'Chapa rejected the withdrawal request' }, 502)
    return json({
      payout_id: reservation.id, merchant_reference: reservation.merchant_reference,
      provider_reference: chapaReference || null, status: creationResult?.status ?? 'pending',
      message: 'Chapa did not return a definitive response. The amount remains reserved for reconciliation. Do not submit the same withdrawal again until its status is checked.',
    }, 202)
  }

  // Persist the provider reference before verification so a temporary verification
  // outage cannot leave an accepted payout with no reference for later reconciliation.
  const { data: referenceResult, error: referenceSaveError } = await admin.rpc('record_tiqet_platform_payout_result', {
    p_payout_id: reservation.id,
    p_status: 'pending',
    p_provider_reference: chapaReference,
    p_provider_service_fee_minor: 0,
    p_provider_payload: { creation_status: 'success', chapa_reference: chapaReference, verification_available: false },
  })
  if (referenceSaveError) {
    console.error('Could not persist accepted Chapa payout reference', referenceSaveError.message)
    return json({ error: 'Chapa accepted the payout but TIQET could not save its provider reference. Do not retry; reconcile this withdrawal.' }, 500)
  }

  let verifyResponse: Response
  let verification: Record<string, any>
  try {
    verifyResponse = await fetch(
      `https://api.chapa.global/v2/payouts/${encodeURIComponent(chapaReference)}/verify`,
      { headers: { Authorization: `Bearer ${chapaKey}` } },
    )
    verification = await verifyResponse.json().catch(() => ({}))
  } catch {
    const { data: verifyResult, error: verifySaveError } = await admin.rpc('record_tiqet_platform_payout_result', {
      p_payout_id: reservation.id,
      p_status: 'pending',
      p_provider_reference: chapaReference,
      p_provider_service_fee_minor: 0,
      p_provider_payload: { creation_status: 'success', chapa_reference: chapaReference, verification_available: false, verification_error: 'Network interruption while checking payout status.' },
    })
    if (verifySaveError) {
      console.error('Could not persist payout verification outage', verifySaveError.message)
      return json({ error: 'Chapa accepted the payout but verification is unavailable and the status update failed. Do not retry; reconcile this withdrawal.' }, 500)
    }
    return json({ payout_id: reservation.id, merchant_reference: reservation.merchant_reference, chapa_reference: chapaReference, status: verifyResult?.status ?? 'pending',
      message: 'Chapa accepted the payout. Verification is temporarily unavailable; the payout remains reserved. Do not submit it again.' }, 202)
  }
  const verified = verification?.data
  const matches = verifyResponse.ok && verification?.status === 'success' && verified &&
    String(verified.merchant_reference ?? '') === reservation.merchant_reference &&
    String(verified.currency ?? '') === 'ETB' && Number(verified.amount) === amountMinor
  const statusMap: Record<string, string> = {
    SUCCESS: 'succeeded', PENDING: 'pending', FAILED: 'failed',
    REVERSED: 'reversed', BLOCKED: 'blocked', AUTH_NEEDED: 'auth_needed',
    OTP_NEEDED: 'otp_needed', OTP_FAILED: 'otp_failed',
  }
  const payoutStatus = matches ? (statusMap[String(verified.status ?? '').toUpperCase()] ?? 'pending') : 'pending'
  const { data: verificationResult, error: verificationUpdateError } = await admin.rpc('record_tiqet_platform_payout_result', {
    p_payout_id: reservation.id,
    p_status: payoutStatus,
    p_provider_reference: chapaReference,
    p_provider_service_fee_minor: matches ? Number(verified.service_fee ?? 0) : 0,
    p_provider_payload: {
      creation_status: String(result?.status ?? 'unknown'), chapa_reference: String(chapaReference),
      verification_available: matches, verified_status: matches ? String(verified.status ?? '') : 'UNKNOWN',
      amount_minor: matches ? Number(verified.amount) : amountMinor,
      currency: matches ? String(verified.currency ?? '') : 'ETB',
      provider_service_fee_minor: matches ? Number(verified.service_fee ?? 0) : 0,
    },
  })
  if (verificationUpdateError) {
    console.error('Could not persist Chapa payout verification result', verificationUpdateError.message)
    return json({ error: 'Chapa accepted the payout, but its verification result could not be persisted. Do not retry; reconcile this withdrawal.' }, 500)
  }
  return json({
    payout_id: reservation.id, merchant_reference: reservation.merchant_reference,
    chapa_reference: chapaReference, amount_etb: reservation.amount_etb, status: verificationResult?.status ?? payoutStatus,
    message: (verificationResult?.status ?? payoutStatus) === 'succeeded'
      ? 'Chapa verified that the withdrawal succeeded.'
      : 'Withdrawal submitted. It remains reserved until Chapa confirms the final status.',
  }, 202)
})
