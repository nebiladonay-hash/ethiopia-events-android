import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.49.1'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}
function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
}
function safeProviderPayload(value: Record<string, any>) {
  const data = value?.data && typeof value.data === 'object' ? value.data : {}
  return {
    status: String(value?.status ?? ''),
    message: String(value?.message ?? ''),
    data: {
      chapa_reference: String(data?.chapa_reference ?? ''),
      payment_reference: String(data?.payment_reference ?? ''),
      amount: Number.isFinite(Number(data?.amount)) ? Number(data.amount) : null,
      currency: String(data?.currency ?? ''),
      status: String(data?.status ?? ''),
      created_at: String(data?.created_at ?? ''),
      updated_at: String(data?.updated_at ?? ''),
    },
  }
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405)
  const authorization = req.headers.get('Authorization')
  if (!authorization?.startsWith('Bearer ')) return json({ error: 'Sign-in required' }, 401)

  const url = Deno.env.get('SUPABASE_URL')
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY')
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')
  const chapaKey = Deno.env.get('CHAPA_PRIVATE_KEY')
  const chapaMode = Deno.env.get('CHAPA_MODE')?.toLowerCase()
  if (!url || !anonKey || !serviceKey) return json({ error: 'Refund service is not configured' }, 503)
  if (!chapaKey || !['test','live'].includes(chapaMode ?? '')) {
    return json({ error: 'Set CHAPA_PRIVATE_KEY and CHAPA_MODE (test or live) in Supabase secrets' }, 503)
  }
  if (chapaMode === 'live' && Deno.env.get('TIQET_LIVE_MARKETPLACE_APPROVED') !== 'true') {
    return json({ error: 'Live refunds are locked until Tiqet has completed Chapa marketplace approval.' }, 403)
  }
  if (chapaMode === 'test' && chapaKey.startsWith('CHAPA_LIVE_')) return json({ error: 'Live Chapa key cannot be used in test mode' }, 503)
  if (chapaMode === 'live' && chapaKey.startsWith('CHAPA_TEST_')) return json({ error: 'Test Chapa key cannot be used in live mode' }, 503)

  const userClient = createClient(url, anonKey, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false, autoRefreshToken: false },
  })
  const admin = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } })
  const { data: authData, error: authError } = await userClient.auth.getUser()
  if (authError || !authData.user) return json({ error: 'Invalid or expired session' }, 401)
  const { data: isAdmin, error: roleError } = await userClient.rpc('is_tiqet_admin')
  if (roleError || isAdmin !== true) return json({ error: 'Tiqet administrator permission required' }, 403)

  let body: { payment_id?: string; amount_minor?: number; reason?: string; idempotency_key?: string }
  try { body = await req.json() } catch { return json({ error: 'Invalid JSON body' }, 400) }
  const paymentId = String(body.payment_id ?? '')
  const reason = String(body.reason ?? '').trim()
  const idempotencyKey = String(body.idempotency_key ?? '').trim()
  const amountMinor = body.amount_minor === undefined || body.amount_minor === null ? null : Number(body.amount_minor)
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(paymentId)) {
    return json({ error: 'A valid payment ID is required' }, 400)
  }
  if (!/^[0-9a-f-]{36}$/i.test(idempotencyKey)) return json({ error: 'A valid idempotency key is required' }, 400)
  if (reason.length < 1 || reason.length > 400) return json({ error: 'Refund reason must contain 1 to 400 characters' }, 400)
  if (amountMinor !== null && (!Number.isSafeInteger(amountMinor) || amountMinor < 100)) {
    return json({ error: 'Partial refund must be at least ETB 1.00 in minor units' }, 400)
  }

  const { data: prepared, error: prepareError } = await userClient.rpc('prepare_chapa_refund', {
    p_payment_id: paymentId,
    p_amount_minor: amountMinor,
    p_reason: reason,
    p_idempotency_key: idempotencyKey,
  })
  if (prepareError || !prepared?.operation) {
    return json({ error: prepareError?.message ?? 'Could not reserve the refund request' }, 409)
  }
  const operation = prepared.operation
  if (operation.status === 'succeeded' || operation.status === 'pending' || operation.status === 'review') {
    return json({ refund_id: operation.id, status: operation.status, provider_reference: operation.provider_reference, replayed: true })
  }
  if (operation.status === 'failed') {
    return json({ refund_id: operation.id, status: 'failed', error: operation.error_message ?? 'This idempotent refund request failed. Create a new request only after reviewing the failure.' }, 409)
  }

  const { data: payment, error: paymentError } = await admin.from('payments')
    .select('id,order_id,provider,provider_reference,merchant_reference,amount_minor,currency')
    .eq('id', paymentId).maybeSingle()
  if (paymentError || !payment || payment.provider !== 'chapa' || !payment.provider_reference) {
    await admin.rpc('record_chapa_refund_result', {
      p_refund_id: operation.id, p_status: 'failed', p_provider_reference: null,
      p_provider_payload: {}, p_error_message: 'Verified Chapa payment reference is unavailable.',
    })
    return json({ error: 'Verified Chapa payment reference is unavailable' }, 409)
  }

  const requestBody: Record<string, unknown> = {
    payment_reference: payment.provider_reference,
    merchant_reference: operation.merchant_reference,
    reason: operation.reason,
    meta: { tiqet_refund_id: operation.id, order_id: payment.order_id },
  }
  if (!operation.request_full_refund) requestBody.amount = operation.amount_minor

  let providerResponse: Response
  let providerJson: Record<string, any>
  try {
    providerResponse = await fetch('https://api.chapa.global/v2/refunds', {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${chapaKey}`,
        'Content-Type': 'application/json',
        'Idempotency-Key': idempotencyKey,
      },
      body: JSON.stringify(requestBody),
    })
    providerJson = await providerResponse.json().catch(() => ({}))
  } catch {
    await admin.rpc('record_chapa_refund_result', {
      p_refund_id: operation.id, p_status: 'submission_unknown', p_provider_reference: null,
      p_provider_payload: {}, p_error_message: 'Network interruption while submitting. Retry this same request key; do not create a new refund.',
    })
    return json({ refund_id: operation.id, status: 'submission_unknown', error: 'Submission result is unknown. Retry the same request; the same idempotency key is preserved.' }, 503)
  }

  const safePayload = safeProviderPayload(providerJson)
  const data = providerJson?.data ?? {}
  const providerReference = String(data?.chapa_reference ?? '')
  if (providerResponse.ok && providerJson?.status === 'success' && providerReference) {
    // Creation confirms that Chapa accepted a refund request, not that the
    // customer has received the funds. Keep it pending until Verify Refund
    // (or a reconciled final webhook) confirms SUCCESS.
    const { data: recorded, error: recordError } = await admin.rpc('record_chapa_refund_result', {
      p_refund_id: operation.id, p_status: 'pending', p_provider_reference: providerReference,
      p_provider_payload: safePayload, p_error_message: null,
    })
    if (recordError) return json({ error: 'Chapa accepted the request but TIQET could not save its result. Keep this request open for reconciliation.', refund_id: operation.id }, 503)
    return json({ refund_id: operation.id, status: 'pending', provider_reference: providerReference, result: recorded })
  }

  const definiteFailure = providerResponse.status >= 400 && providerResponse.status < 500 &&
    ![408,409,425,429].includes(providerResponse.status)
  const mapped = definiteFailure ? 'failed' : 'submission_unknown'
  const message = String(providerJson?.message ?? `Chapa returned HTTP ${providerResponse.status}`).slice(0,500)
  const { error: recordError } = await admin.rpc('record_chapa_refund_result', {
    p_refund_id: operation.id, p_status: mapped, p_provider_reference: providerReference || null,
    p_provider_payload: safePayload, p_error_message: message,
  })
  if (recordError) return json({ error: 'Could not persist Chapa response; reconcile this refund before retrying.', refund_id: operation.id }, 503)
  return json({ refund_id: operation.id, status: mapped, error: message }, definiteFailure ? 502 : 503)
})
