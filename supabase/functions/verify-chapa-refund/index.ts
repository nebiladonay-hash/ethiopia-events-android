import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.49.1'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}
function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
}
function safePayload(value: Record<string, any>) {
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
      reason: String(data?.reason ?? ''),
      created_at: String(data?.created_at ?? ''),
      processed_at: String(data?.processed_at ?? ''),
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
  if (!url || !anonKey || !serviceKey) return json({ error: 'Refund verification is not configured' }, 503)
  if (!chapaKey || !['test','live'].includes(chapaMode ?? '')) return json({ error: 'Chapa credentials or mode are not configured' }, 503)
  if (chapaMode === 'live' && Deno.env.get('TIQET_LIVE_MARKETPLACE_APPROVED') !== 'true') {
    return json({ error: 'Live refund verification is locked until Tiqet marketplace approval is recorded.' }, 403)
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

  let body: { refund_id?: string }
  try { body = await req.json() } catch { return json({ error: 'Invalid JSON body' }, 400) }
  const refundId = String(body.refund_id ?? '')
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(refundId)) {
    return json({ error: 'A valid refund ID is required' }, 400)
  }

  const { data: operation, error: operationError } = await admin.from('chapa_refund_operations')
    .select('id,payment_id,order_id,merchant_reference,provider_reference,amount_minor,status')
    .eq('id', refundId).maybeSingle()
  if (operationError || !operation) return json({ error: 'Refund operation not found' }, 404)
  if (operation.status === 'succeeded') return json({ refund_id: operation.id, status: 'succeeded', already_verified: true })
  if (!operation.provider_reference) return json({ error: 'Chapa has not returned a refund reference yet. Retry the original refund request first.' }, 409)

  const { data: payment, error: paymentError } = await admin.from('payments')
    .select('provider_reference,merchant_reference,amount_minor,currency')
    .eq('id', operation.payment_id).maybeSingle()
  if (paymentError || !payment) return json({ error: 'Original payment record not found' }, 404)

  let response: Response
  let payload: Record<string, any>
  try {
    response = await fetch(`https://api.chapa.global/v2/refunds/${encodeURIComponent(operation.provider_reference)}/verify`, {
      method: 'GET',
      headers: { Authorization: `Bearer ${chapaKey}` },
    })
    payload = await response.json().catch(() => ({}))
  } catch {
    return json({ error: 'Chapa verification is temporarily unavailable. The refund remains open; retry verification.' }, 503)
  }
  if (!response.ok || payload?.status !== 'success' || !payload?.data) {
    return json({ error: String(payload?.message ?? `Chapa verification returned HTTP ${response.status}`) }, response.status >= 500 ? 503 : 502)
  }

  const details = payload.data
  const providerReference = String(details.chapa_reference ?? '')
  const paymentReference = String(details.payment_reference ?? '')
  const amount = Number(details.amount)
  const currency = String(details.currency ?? '')
  if (providerReference !== operation.provider_reference ||
      paymentReference !== payment.provider_reference ||
      !Number.isSafeInteger(amount) || amount !== Number(operation.amount_minor) ||
      currency !== 'ETB') {
    await admin.rpc('record_chapa_refund_result', {
      p_refund_id: operation.id, p_status: 'review', p_provider_reference: operation.provider_reference,
      p_provider_payload: safePayload(payload),
      p_error_message: 'Chapa verification data did not match the stored refund request. Manual review required.',
    })
    return json({ error: 'Verified refund details do not match TIQET records. The operation is flagged for manual review.' }, 409)
  }

  const rawStatus = String(details.status ?? '').toUpperCase()
  const mapped = rawStatus === 'SUCCESS' ? 'succeeded'
    : rawStatus === 'FAILED' ? 'failed'
    : rawStatus === 'PENDING' ? 'pending'
    : 'review'
  const { data: recorded, error: recordError } = await admin.rpc('record_chapa_refund_result', {
    p_refund_id: operation.id, p_status: mapped, p_provider_reference: operation.provider_reference,
    p_provider_payload: safePayload(payload),
    p_error_message: mapped === 'review' ? `Unrecognized Chapa refund status: ${rawStatus || 'empty'}`
      : mapped === 'failed' ? 'Chapa verification confirmed that the refund failed.' : null,
  })
  if (recordError) return json({ error: 'Could not save the verified refund status. Retry verification.' }, 503)
  return json({ refund_id: operation.id, status: mapped, provider_status: rawStatus, result: recorded })
})
