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

  const supabaseUrl = Deno.env.get('SUPABASE_URL')!
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY')!
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
  const chapaKey = Deno.env.get('CHAPA_PRIVATE_KEY')
  const chapaMode = Deno.env.get('CHAPA_MODE')?.toLowerCase()
  if (!chapaKey || !['test', 'live'].includes(chapaMode ?? '')) return json({ error: 'Set CHAPA_PRIVATE_KEY and CHAPA_MODE (test or live) in Supabase secrets' }, 503)
  const keyMode = chapaKey.startsWith('CHAPA_TEST_') ? 'test' : chapaKey.startsWith('CHAPA_LIVE_') ? 'live' : null
  if (keyMode && keyMode !== chapaMode) return json({ error: 'Chapa API key environment does not match CHAPA_MODE' }, 503)
  if (chapaMode === 'live' && Deno.env.get('TIQET_LIVE_MARKETPLACE_APPROVED') !== 'true') {
    return json({ error: 'Live checkout is locked until Tiqet has written marketplace approval and merchant activation from Chapa.' }, 403)
  }

  const userClient = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authHeader } },
    auth: { persistSession: false, autoRefreshToken: false },
  })
  const admin = createClient(supabaseUrl, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  })

  const { data: userResult, error: userError } = await userClient.auth.getUser()
  if (userError || !userResult.user) return json({ error: 'Invalid or expired session' }, 401)

  let body: { ticket_type_id?: string; quantity?: number; payment_method?: string }
  try { body = await req.json() } catch { return json({ error: 'Invalid JSON body' }, 400) }
  if (!body.ticket_type_id || !Number.isInteger(body.quantity) || (body.quantity ?? 0) < 1 || (body.quantity ?? 0) > 10) {
    return json({ error: 'ticket_type_id and quantity from 1 to 10 are required' }, 400)
  }

  const { data: hold, error: holdError } = await userClient.rpc('create_order_hold', {
    p_ticket_type_id: body.ticket_type_id,
    p_quantity: body.quantity,
  })
  if (holdError || !hold?.order_id) return json({ error: holdError?.message ?? 'Could not reserve tickets' }, 409)

  const failHold = async (reason: string) => {
    await admin.rpc('fail_order_payment', { p_order_id: hold.order_id, p_reason: reason })
  }
  const { data: item, error: itemError } = await admin
    .from('order_items').select('event_id').eq('order_id', hold.order_id).single()
  if (itemError || !item) {
    await failHold('Could not resolve event organiser')
    return json({ error: 'Could not resolve the event organiser. Please try again.' }, 500)
  }
  const { data: event, error: eventError } = await admin
    .from('events').select('organisation_id').eq('id', item.event_id).single()
  if (eventError || !event?.organisation_id) {
    await failHold('Could not resolve event organisation')
    return json({ error: 'Could not resolve the event organiser. Please try again.' }, 500)
  }
  const { data: organisation, error: organisationError } = await admin
    .from('organisations')
    .select('id, name, status, chapa_subaccount_reference')
    .eq('id', event.organisation_id).single()
  const { data: genericAccount } = await admin.from('organisation_payment_accounts')
    .select('provider_account_reference, status')
    .eq('organisation_id', event.organisation_id).eq('provider', 'chapa').eq('status', 'active').maybeSingle()
  const organiserAccountReference = genericAccount?.provider_account_reference ?? organisation?.chapa_subaccount_reference
  if (organisationError || !organisation || organisation.status !== 'verified' || !organiserAccountReference) {
    await failHold('Organiser payout account is not configured')
    return json({ error: 'This organiser has not completed payout setup yet. Please try another event or contact the organiser.' }, 409)
  }

  const { data: pricing } = await admin
    .from('platform_financial_settings')
    .select('organiser_commission_rate')
    .eq('singleton', true)
    .single()
  const commissionRate = Number(pricing?.organiser_commission_rate ?? 0.05)
  const subtotalEtb = Number(hold.subtotal_etb)
  const organiserNetEtb = Math.max(0, Math.round((subtotalEtb * (1 - commissionRate) + Number.EPSILON) * 100) / 100)
  const organiserSplitMinor = Math.round(organiserNetEtb * 100)

  let preferredMethods: string[] | undefined
  if (body.payment_method) {
    const methodsResponse = await fetch('https://api.chapa.global/v2/payments/methods', {
      headers: { Authorization: `Bearer ${chapaKey}` },
    })
    const methodsJson = await methodsResponse.json().catch(() => ({}))
    const methods = Array.isArray(methodsJson?.data) ? methodsJson.data : []
    const selected = methods.find((m: Record<string, any>) =>
      m.slug === body.payment_method && m.can_process_payments === true &&
      m.supported_currencies?.ETB?.countries?.ET?.is_enabled === true,
    )
    if (!methodsResponse.ok || !selected) {
      await failHold('Selected payment method is not enabled')
      return json({ error: 'That payment method is currently unavailable. Choose another method.' }, 400)
    }
    preferredMethods = [selected.slug]
  }

  const { data: profile } = await admin.from('profiles').select('full_name, phone').eq('id', userResult.user.id).maybeSingle()
  const nameParts = (profile?.full_name ?? '').trim().split(/\s+/).filter(Boolean)
  const customer: Record<string, string> = { email: userResult.user.email ?? '' }
  if (nameParts.length) customer.first_name = nameParts[0]
  if (nameParts.length > 1) customer.last_name = nameParts.slice(1).join(' ')
  if (profile?.phone) customer.phone_number = profile.phone

  const checkoutBody: Record<string, unknown> = {
    amount: hold.amount_minor,
    currency: 'ETB',
    merchant_reference: hold.merchant_reference,
    customer,
    meta: { order_id: hold.order_id, organisation_id: organisation.id, app: 'tiqet' },
    customization: {
      title: 'Tiqet ticket order',
      description: `${hold.quantity} ticket(s). Tickets ETB ${Number(hold.subtotal_etb).toFixed(2)} + Tiqet service fee ETB ${Number(hold.buyer_service_fee_etb).toFixed(2)}.`,
    },
    subaccounts: [{
      subaccount_reference: organiserAccountReference,
      split_type: 'flat',
      split_value: organiserSplitMinor,
    }],
  }
  if (preferredMethods) checkoutBody.preferred_payment_methods = preferredMethods

  const { error: paymentInsertError } = await admin.from('payments').insert({
    order_id: hold.order_id,
    provider: 'chapa',
    merchant_reference: hold.merchant_reference,
    provider_reference: null,
    checkout_url: null,
    amount_minor: hold.amount_minor,
    currency: 'ETB',
    status: 'initiated',
    idempotency_key: hold.merchant_reference,
    payment_method: preferredMethods?.[0] ?? null,
    provider_payload: {
      organiser_split_minor: organiserSplitMinor,
      organiser_subaccount_reference: organiserAccountReference,
      settlement_split_minor: organiserSplitMinor,
      preferred_payment_methods: preferredMethods ?? null,
    },
  })
  if (paymentInsertError) {
    await failHold('Could not persist payment attempt before provider initialization')
    return json({ error: 'Could not create the secure payment record. Please try again.' }, 500)
  }

  const { data: persistedPayment } = await admin.from('payments').select('id').eq('order_id', hold.order_id).single()
  if (persistedPayment?.id) {
    const { error: eventError } = await admin.from('payment_attempt_events').insert({
      payment_id: persistedPayment.id, order_id: hold.order_id, provider: 'chapa', event_type: 'intent_created',
      safe_metadata: { amount_minor: hold.amount_minor, currency: 'ETB', payment_method: preferredMethods?.[0] ?? null },
    })
    if (eventError) console.error('Payment attempt audit event insert failed', eventError.message)
  }

  const chapaResponse = await fetch('https://api.chapa.global/v2/payments/hosted', {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${chapaKey}`,
      'Content-Type': 'application/json',
      'Idempotency-Key': hold.merchant_reference,
    },
    body: JSON.stringify(checkoutBody),
  })
  const chapa = await chapaResponse.json().catch(() => ({}))
  const checkoutUrl = chapa?.data?.checkout_url
  if (!chapaResponse.ok || chapa?.status !== 'success' || !checkoutUrl) {
    await failHold(`Chapa initialization failed (${chapaResponse.status})`)
    return json({ error: chapa?.message ?? 'Could not initialize payment' }, 502)
  }

  const { error: paymentUpdateError } = await admin.from('payments').update({
    checkout_url: checkoutUrl,
    provider_payload: {
      checkout_created: true,
      organiser_split_minor: organiserSplitMinor,
      organiser_subaccount_reference: organiserAccountReference,
      settlement_split_minor: organiserSplitMinor,
      preferred_payment_methods: preferredMethods ?? null,
    },
    updated_at: new Date().toISOString(),
  }).eq('order_id', hold.order_id)
  if (paymentUpdateError) console.error('Could not update stored Chapa checkout metadata', paymentUpdateError.message)
  if (persistedPayment?.id) {
    const { error: checkoutEventError } = await admin.from('payment_attempt_events').insert({
      payment_id: persistedPayment.id, order_id: hold.order_id, provider: 'chapa', event_type: 'checkout_created',
      safe_metadata: { checkout_created: true },
    })
    if (checkoutEventError) console.error('Checkout audit event insert failed', checkoutEventError.message)
  }

  return json({
    order_id: hold.order_id,
    merchant_reference: hold.merchant_reference,
    checkout_url: checkoutUrl,
    subtotal_etb: hold.subtotal_etb,
    service_fee_etb: hold.buyer_service_fee_etb,
    total_etb: hold.total_etb,
    hold_expires_at: hold.hold_expires_at,
  })
})
