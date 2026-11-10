import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.49.1'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}
function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
}
type RefundReservation = {
  refund_id: string
  merchant_reference: string
  provider_reference: string | null
  amount_minor: number
  currency: string
  status: string
  request_full_refund: boolean
  duplicate: boolean
}
function getChapaConfig() {
  const key = Deno.env.get('CHAPA_PRIVATE_KEY')
  const mode = Deno.env.get('CHAPA_MODE')?.toLowerCase()
  if (!key || !['test', 'live'].includes(mode ?? '')) {
    return { error: 'Payment provider is not configured. Set CHAPA_PRIVATE_KEY and CHAPA_MODE.' }
  }
  const keyMode = key.startsWith('CHAPA_TEST_') ? 'test' : key.startsWith('CHAPA_LIVE_') ? 'live' : null
  if (keyMode && keyMode !== mode) return { error: 'Chapa API key environment does not match CHAPA_MODE.' }
  return { key, mode }
}
Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405)

  const authorization = req.headers.get('Authorization')
  if (!authorization?.startsWith('Bearer ')) return json({ error: 'Sign-in required' }, 401)
  const supabaseUrl = Deno.env.get('SUPABASE_URL')
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY')
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')
  if (!supabaseUrl || !anonKey || !serviceKey) return json({ error: 'Payment service is not configured' }, 503)

  const userClient = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false, autoRefreshToken: false },
  })
  const admin = createClient(supabaseUrl, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } })
  const { data: auth, error: authError } = await userClient.auth.getUser()
  if (authError || !auth.user) return json({ error: 'Invalid or expired session' }, 401)

  const { data: staff } = await admin.from('tiqet_staff_roles')
    .select('role').eq('user_id', auth.user.id).in('role', ['admin', 'super_admin']).maybeSingle()
  const isPlatformOwner = auth.user.app_metadata?.tiqet_role === 'platform_owner'
  if (!isPlatformOwner && !staff) return json({ error: 'Finance administrator access required' }, 403)

  const config = getChapaConfig()
  if ('error' in config) return json({ error: config.error }, 503)

  let body: { payment_id?: string; amount_minor?: number | null; reason?: string; idempotency_key?: string }
  try { body = await req.json() } catch { return json({ error: 'Invalid JSON body' }, 400) }
  if (!body.payment_id || !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(body.payment_id)) {
    return json({ error: 'A valid payment_id is required' }, 400)
  }
  if (body.amount_minor !== undefined && body.amount_minor !== null &&
      (!Number.isSafeInteger(body.amount_minor) || body.amount_minor < 100)) {
    return json({ error: 'amount_minor must be an integer of at least 100, or omitted for a full refund' }, 400)
  }
  const reason = String(body.reason ?? '').trim()
  if (!reason || reason.length > 400) return json({ error: 'A refund reason from 1 to 400 characters is required' }, 400)
  const idempotencyKey = String(body.idempotency_key ?? '')
  if (!/^[A-Za-z0-9._:-]{8,128}$/.test(idempotencyKey)) {
    return json({ error: 'idempotency_key must contain 8 to 128 letters, numbers, dots, underscores, colons or hyphens' }, 400)
  }

  const { data: payment, error: paymentError } = await admin.from('payments')
    .select('id, order_id, provider, merchant_reference, provider_reference, provider_payment_reference, amount_minor, currency, status')
    .eq('id', body.payment_id).maybeSingle()
  if (paymentError || !payment) return json({ error: 'Payment record not found' }, 404)
  if (payment.provider !== 'chapa' || payment.currency !== 'ETB') {
    return json({ error: 'This refund workflow supports Chapa ETB payments only' }, 409)
  }
  const paymentReference = payment.provider_payment_reference || payment.provider_reference
  if (!paymentReference) return json({ error: 'Verified Chapa payment reference is missing; reconcile the payment first' }, 409)

  // Reserve the amount under an idempotency key before contacting Chapa.
  // Retrying the same request key returns the same reservation and never
  // opens a second independent refund.
  const { data: reservationData, error: reservationError } = await admin.rpc('reserve_chapa_refund', {
    p_payment_id: payment.id,
    p_amount_minor: body.amount_minor ?? null,
    p_reason: reason,
    p_idempotency_key: idempotencyKey,
    p_requested_by: auth.user.id,
  })
  if (reservationError || !reservationData) {
    return json({ error: reservationError?.message ?? 'Could not reserve this refund' }, 409)
  }
  const refund = reservationData as RefundReservation
  if (refund.status === 'succeeded' || refund.status === 'failed') {
    return json({ refund_id: refund.refund_id, status: refund.status, amount_minor: refund.amount_minor, duplicate: true })
  }
  if (refund.provider_reference) {
    return json({
      refund_id: refund.refund_id, merchant_reference: refund.merchant_reference,
      provider_reference: refund.provider_reference, amount_minor: refund.amount_minor,
      currency: refund.currency, status: refund.status, duplicate: true,
      next_step: 'Use verify-chapa-refund to refresh the provider status.',
    })
  }

  // Chapa requires the original payment to be successful before a refund.
  // If verification is temporarily unavailable, leave the reservation intact;
  // the same idempotency key can safely retry this request.
  let paymentVerification: any
  try {
    const verifyResponse = await fetch(
      `https://api.chapa.global/v2/payments/${encodeURIComponent(paymentReference)}/verify`,
      { headers: { Authorization: `Bearer ${config.key}` } },
    )
    paymentVerification = await verifyResponse.json().catch(() => ({}))
    if (!verifyResponse.ok || paymentVerification?.status !== 'success' || !paymentVerification?.data) {
      return json({ error: 'Chapa payment verification is unavailable; retry with the same idempotency key.' }, 503)
    }
  } catch {
    return json({ error: 'Could not reach Chapa to verify the original payment; retry with the same idempotency key.' }, 503)
  }

  const paymentData = paymentVerification.data
  const verifiedPaymentReference = String(paymentData.chapa_reference ?? paymentReference)
  const verifiedMerchantReference = String(paymentData.merchant_reference ?? '')
  if (String(paymentData.status ?? '').toUpperCase() !== 'SUCCESS' ||
      Number(paymentData.amount) !== Number(payment.amount_minor) ||
      String(paymentData.currency ?? '') !== payment.currency ||
      verifiedMerchantReference !== payment.merchant_reference ||
      verifiedPaymentReference !== paymentReference) {
    await admin.rpc('record_chapa_refund_result', {
      p_refund_id: refund.refund_id,
      p_provider_reference: null,
      p_provider_status: 'REVIEW',
      p_provider_payload: { reason: 'Original payment verification did not match the stored payment', provider_status: String(paymentData.status ?? 'UNKNOWN') },
      p_error_message: 'Original payment verification did not match the stored payment.',
    })
    return json({ error: 'Original payment could not be confirmed against TIQET records. Refund request moved to manual review.' }, 409)
  }

  const requestBody: Record<string, unknown> = {
    payment_reference: paymentReference,
    merchant_reference: refund.merchant_reference,
    reason,
    meta: { app: 'tiqet', payment_id: payment.id, order_id: payment.order_id, refund_id: refund.refund_id },
  }
  if (!refund.request_full_refund) requestBody.amount = refund.amount_minor

  let chapaResponse: Response
  let chapa: any
  try {
    chapaResponse = await fetch('https://api.chapa.global/v2/refunds', {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${config.key}`,
        'Content-Type': 'application/json',
        'Idempotency-Key': idempotencyKey,
      },
      body: JSON.stringify(requestBody),
    })
    chapa = await chapaResponse.json().catch(() => ({}))
  } catch {
    // Keep the reservation in requested state. Chapa may have accepted the
    // request before a network timeout; the idempotency key makes retries safe.
    return json({ error: 'Chapa did not return a response. Retry the same request using the same idempotency key.', refund_id: refund.refund_id }, 503)
  }

  if (!chapaResponse.ok || chapa?.status !== 'success' || !chapa?.data) {
    if (chapaResponse.status >= 400 && chapaResponse.status < 500 && chapaResponse.status !== 409) {
      await admin.rpc('record_chapa_refund_result', {
        p_refund_id: refund.refund_id, p_provider_reference: null, p_provider_status: 'FAILED',
        p_provider_payload: { http_status: chapaResponse.status, error_code: String(chapa?.error?.code ?? '') },
        p_error_message: `Chapa rejected the refund request (HTTP ${chapaResponse.status}).`,
      })
      return json({ error: 'Chapa rejected the refund request. The reservation was marked failed.' }, 502)
    }
    if (chapaResponse.status === 409) {
      await admin.rpc('record_chapa_refund_result', {
        p_refund_id: refund.refund_id, p_provider_reference: null, p_provider_status: 'REVIEW',
        p_provider_payload: { http_status: 409, error_code: String(chapa?.error?.code ?? '') },
        p_error_message: 'Chapa returned a conflict; provider state needs verification.',
      })
    }
    return json({ error: 'Chapa did not confirm refund creation. The request is retained for safe reconciliation.', refund_id: refund.refund_id }, 502)
  }

  const data = chapa.data
  const providerReference = String(data.chapa_reference ?? '')
  const responsePaymentReference = String(data.payment_reference ?? '')
  const responseAmount = Number(data.amount)
  const responseCurrency = String(data.currency ?? '')
  if (!providerReference || responsePaymentReference !== paymentReference ||
      responseAmount !== Number(refund.amount_minor) || responseCurrency !== 'ETB') {
    await admin.rpc('record_chapa_refund_result', {
      p_refund_id: refund.refund_id,
      p_provider_reference: providerReference || null,
      p_provider_status: 'REVIEW',
      p_provider_payload: {
        chapa_reference: providerReference || null, payment_reference: responsePaymentReference,
        amount: Number.isFinite(responseAmount) ? responseAmount : null, currency: responseCurrency,
        status: String(data.status ?? 'UNKNOWN'),
      },
      p_error_message: 'Chapa refund response did not match the reserved refund.',
    })
    return json({ error: 'Chapa returned refund details that do not match TIQET records. Manual review is required.', refund_id: refund.refund_id }, 409)
  }

  const providerStatus = String(data.status ?? '').toUpperCase()
  const { data: saved, error: saveError } = await admin.rpc('record_chapa_refund_result', {
    p_refund_id: refund.refund_id,
    p_provider_reference: providerReference,
    p_provider_status: providerStatus,
    p_provider_payload: {
      chapa_reference: providerReference, payment_reference: responsePaymentReference,
      amount: responseAmount, currency: responseCurrency, status: providerStatus,
      reason: String(data.reason ?? reason), created_at: data.created_at ?? null,
      updated_at: data.updated_at ?? null,
    },
    p_error_message: null,
  })
  if (saveError || !saved) return json({ error: 'Chapa accepted the refund but TIQET could not save the provider status. Verify the refund before retrying.' }, 500)

  return json({
    refund_id: refund.refund_id,
    merchant_reference: refund.merchant_reference,
    provider_reference: providerReference,
    amount_minor: refund.amount_minor,
    currency: 'ETB',
    status: saved.status ?? providerStatus.toLowerCase(),
    requires_manual_reconciliation: true,
  })
})
