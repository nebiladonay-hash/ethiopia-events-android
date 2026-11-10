import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.49.1'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}
function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
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

  let body: { refund_id?: string }
  try { body = await req.json() } catch { return json({ error: 'Invalid JSON body' }, 400) }
  if (!body.refund_id || !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(body.refund_id)) {
    return json({ error: 'A valid refund_id is required' }, 400)
  }

  const { data: refund, error: refundError } = await admin.from('payment_refunds')
    .select('id, payment_id, order_id, provider, provider_reference, amount_minor, currency, merchant_reference, status')
    .eq('id', body.refund_id).maybeSingle()
  if (refundError || !refund) return json({ error: 'Refund record not found' }, 404)
  if (refund.provider !== 'chapa' || refund.currency !== 'ETB') {
    return json({ error: 'This verification endpoint supports Chapa ETB refunds only' }, 409)
  }
  if (!refund.provider_reference) {
    return json({ error: 'Chapa has not assigned a refund reference yet. Retry the original create request using its original idempotency key.' }, 409)
  }
  if (refund.status === 'failed') {
    return json({ refund_id: refund.id, status: 'failed', already_final: true })
  }

  const { data: payment, error: paymentError } = await admin.from('payments')
    .select('provider_reference, provider_payment_reference, merchant_reference, amount_minor, currency')
    .eq('id', refund.payment_id).maybeSingle()
  if (paymentError || !payment) return json({ error: 'Related payment record not found' }, 404)
  const paymentReference = payment.provider_payment_reference || payment.provider_reference
  if (!paymentReference || payment.currency !== 'ETB') {
    return json({ error: 'Original Chapa payment reference is missing or invalid' }, 409)
  }

  let response: Response
  let result: any
  try {
    response = await fetch(
      `https://api.chapa.global/v2/refunds/${encodeURIComponent(refund.provider_reference)}/verify`,
      { headers: { Authorization: `Bearer ${config.key}` } },
    )
    result = await response.json().catch(() => ({}))
  } catch {
    return json({ error: 'Could not reach Chapa to verify this refund. Retry verification.' }, 503)
  }
  if (!response.ok || result?.status !== 'success' || !result?.data) {
    return json({ error: 'Chapa refund verification is temporarily unavailable. Retry verification.' }, 503)
  }

  const data = result.data
  const verifiedReference = String(data.chapa_reference ?? '')
  const verifiedPaymentReference = String(data.payment_reference ?? '')
  const verifiedAmount = Number(data.amount)
  const verifiedCurrency = String(data.currency ?? '')
  const providerStatus = String(data.status ?? '').toUpperCase()
  if (verifiedReference !== refund.provider_reference ||
      verifiedPaymentReference !== paymentReference ||
      verifiedAmount !== Number(refund.amount_minor) ||
      verifiedCurrency !== refund.currency) {
    const { error: saveReviewError } = await admin.rpc('record_chapa_refund_result', {
      p_refund_id: refund.id,
      p_provider_reference: refund.provider_reference,
      p_provider_status: 'REVIEW',
      p_provider_payload: {
        chapa_reference: verifiedReference || null,
        payment_reference: verifiedPaymentReference,
        amount: Number.isFinite(verifiedAmount) ? verifiedAmount : null,
        currency: verifiedCurrency,
        status: providerStatus || 'UNKNOWN',
      },
      p_error_message: 'Chapa refund verification details did not match the stored refund.',
    })
    if (saveReviewError) return json({ error: 'Refund mismatch detected and could not be persisted for manual review' }, 500)
    return json({ error: 'Chapa refund details do not match TIQET records. Manual review is required.' }, 409)
  }

  const { data: saved, error: saveError } = await admin.rpc('record_chapa_refund_result', {
    p_refund_id: refund.id,
    p_provider_reference: refund.provider_reference,
    p_provider_status: providerStatus,
    p_provider_payload: {
      chapa_reference: verifiedReference,
      payment_reference: verifiedPaymentReference,
      amount: verifiedAmount,
      currency: verifiedCurrency,
      status: providerStatus,
      reason: String(data.reason ?? ''),
      created_at: data.created_at ?? null,
      processed_at: data.processed_at ?? null,
    },
    p_error_message: null,
  })
  if (saveError || !saved) return json({ error: 'Could not persist the verified Chapa refund status' }, 500)

  return json({
    refund_id: refund.id,
    provider_reference: refund.provider_reference,
    amount_minor: refund.amount_minor,
    currency: refund.currency,
    status: saved.status ?? providerStatus.toLowerCase(),
    requires_manual_reconciliation: saved.requires_manual_review ?? false,
  })
})
