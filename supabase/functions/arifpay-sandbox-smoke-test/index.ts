import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.49.1'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  })
}

function getString(value: unknown): string {
  return typeof value === 'string' ? value.trim() : ''
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405)

  const authorization = req.headers.get('Authorization')
  if (!authorization?.startsWith('Bearer ')) return json({ error: 'Sign-in required' }, 401)

  const supabaseUrl = Deno.env.get('SUPABASE_URL')
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY')
  if (!supabaseUrl || !anonKey) return json({ error: 'Supabase auth is not configured' }, 503)

  const userClient = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false, autoRefreshToken: false },
  })
  const { data: auth, error: authError } = await userClient.auth.getUser()
  if (authError || !auth.user) return json({ error: 'Invalid or expired session' }, 401)
  if (auth.user.app_metadata?.tiqet_role !== 'platform_owner') {
    return json({ error: 'Platform-owner access required' }, 403)
  }

  let body: { flow?: string; sim_mode?: string }
  try {
    body = await req.json()
  } catch {
    return json({ error: 'Invalid JSON body' }, 400)
  }

  const flow = getString(body.flow || 'hosted_session').toLowerCase()
  const simMode = getString(body.sim_mode || 'SUCCESS').toUpperCase()
  if (!['hosted_session', 'telebirr_direct'].includes(flow)) {
    return json({ error: 'flow must be hosted_session or telebirr_direct' }, 400)
  }
  if (!['SUCCESS', 'FAIL'].includes(simMode)) {
    return json({ error: 'sim_mode must be SUCCESS or FAIL' }, 400)
  }

  // This is a fixed sandbox-only smoke test: no order, payment, ticket, or ledger
  // records are created or updated. The public key is published in ArifPay's
  // official Sandbox Postman collection; override it privately only if ArifPay
  // issues a different sandbox key for this workspace.
  const sandboxKey = Deno.env.get('ARIFPAY_SANDBOX_KEY') || 'arif-sandbox-portal-key'
  const nonce = `tiqet-sandbox-${crypto.randomUUID()}`
  const notifyUrl = `${supabaseUrl.replace(/\/$/, '')}/functions/v1/arifpay-sandbox-webhook`
  const expiresAt = new Date(Date.now() + 30 * 60 * 1000).toISOString().slice(0, 19)

  const payload = {
    cancelUrl: 'https://payment.arifpay.org/Cancel',
    phone: flow === 'telebirr_direct' ? '251900000000' : '251911000000',
    email: 'sandbox@example.com',
    nonce,
    errorUrl: 'https://payment.arifpay.org/Error',
    notifyUrl,
    successUrl: 'https://payment.arifpay.org/success',
    expireDate: expiresAt,
    items: [{
      name: 'Tiqet sandbox test ticket',
      quantity: 1,
      price: 10,
      description: 'Sandbox-only integration smoke test; not a real ticket',
    }],
    lang: 'EN',
  }

  const endpoint = flow === 'telebirr_direct'
    ? '/api/sandbox/c2b/telebirr-ussd/direct/transfer'
    : '/api/sandbox/c2b/session'

  let providerResponse: Response
  try {
    providerResponse = await fetch(`https://gateway.arifpay.org${endpoint}`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'x-arifpay-key': sandboxKey,
        'x-arifpay-sim-mode': simMode,
        'x-arifpay-fee-source': 'MERCHANT',
      },
      body: JSON.stringify(payload),
      signal: AbortSignal.timeout(20_000),
    })
  } catch (error) {
    console.error('ArifPay sandbox request failed before an HTTP response', error)
    return json({
      error: 'Could not reach the ArifPay sandbox gateway',
      sandbox_only: true,
      live_charges_possible: false,
    }, 502)
  }

  const responseText = await providerResponse.text()
  let providerPayload: Record<string, unknown> = {}
  try {
    const parsed = JSON.parse(responseText)
    if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) providerPayload = parsed
    else providerPayload = { response: parsed }
  } catch {
    providerPayload = { response_text: responseText.slice(0, 1500) }
  }

  const data = providerPayload.data && typeof providerPayload.data === 'object'
    ? providerPayload.data as Record<string, unknown>
    : providerPayload
  const sessionId = data.sessionId ?? data.uuid ?? providerPayload.sessionId ?? null
  const transaction = data.transaction && typeof data.transaction === 'object'
    ? data.transaction as Record<string, unknown>
    : {}
  const checkoutUrl = data.checkoutUrl ?? data.checkout_url ?? data.paymentUrl ?? data.payment_url ?? null
  const transactionId = data.transactionId ?? transaction.transactionId ?? null
  const transactionStatus = data.transactionStatus ?? transaction.transactionStatus ?? null
  const providerError = providerPayload.error === true || !providerResponse.ok

  console.info('ArifPay sandbox smoke-test response', {
    flow, sim_mode: simMode, http_status: providerResponse.status,
    provider_error: providerError, nonce,
  })

  return json({
    sandbox_only: true,
    live_charges_possible: false,
    order_created: false,
    payment_record_created: false,
    flow,
    sim_mode: simMode,
    amount_etb: 10,
    nonce,
    http_status: providerResponse.status,
    provider_error: providerError,
    provider_message: providerPayload.msg ?? providerPayload.message ?? null,
    session_id: sessionId,
    checkout_url: typeof checkoutUrl === 'string' ? checkoutUrl : null,
    transaction_id: transactionId,
    transaction_status: transactionStatus,
    provider_response_keys: Object.keys(providerPayload),
    note: flow === 'hosted_session'
      ? 'Session creation alone does not mean a payment succeeded.'
      : 'This is an ArifPay simulator response and must never be treated as a real Tiqet payment.',
  }, providerResponse.ok && !providerError ? 200 : 502)
})
