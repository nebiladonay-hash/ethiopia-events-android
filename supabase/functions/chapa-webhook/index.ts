import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.49.1'
function hex(bytes: Uint8Array): string {
  return Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('')
}
function constantTimeEqual(a: string, b: string): boolean {
  if (!/^[a-f0-9]{64}$/i.test(a) || !/^[a-f0-9]{64}$/i.test(b)) return false
  let diff = 0
  for (let i = 0; i < 64; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i)
  return diff === 0
}
function toArrayBuffer(bytes: Uint8Array): ArrayBuffer {
  const buffer = new ArrayBuffer(bytes.byteLength)
  new Uint8Array(buffer).set(bytes)
  return buffer
}
async function hmacSha256(secret: string, rawBytes: Uint8Array): Promise<string> {
  const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(secret),
    { name: 'HMAC', hash: 'SHA-256' }, false, ['sign'])
  const signature = await crypto.subtle.sign('HMAC', key, toArrayBuffer(rawBytes))
  return hex(new Uint8Array(signature))
}
async function sha256(rawBytes: Uint8Array): Promise<string> {
  return hex(new Uint8Array(await crypto.subtle.digest('SHA-256', toArrayBuffer(rawBytes))))
}
function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } })
}
Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405)
  const rawBytes = new Uint8Array(await req.arrayBuffer())
  const rawBody = new TextDecoder().decode(rawBytes)
  const received = req.headers.get('x-chapa-signature') ?? ''
  const webhookSecret = Deno.env.get('CHAPA_WEBHOOK_SECRET')
  const chapaPrivateKey = Deno.env.get('CHAPA_PRIVATE_KEY')
  if (!webhookSecret || !chapaPrivateKey) return json({ error: 'Webhook is not configured' }, 503)
  const expected = await hmacSha256(webhookSecret, rawBytes)
  if (!constantTimeEqual(received.toLowerCase(), expected.toLowerCase())) return json({ error: 'Invalid webhook signature' }, 401)
  let event: Record<string, unknown>
  try { event = JSON.parse(rawBody) } catch { return json({ error: 'Invalid JSON' }, 400) }
  const expectedMode = Deno.env.get('CHAPA_MODE')?.toLowerCase()
  if (!['test', 'live'].includes(expectedMode ?? '')) {
    return json({ error: 'CHAPA_MODE must be configured as test or live before accepting Chapa webhooks' }, 503)
  }
  const keyMode = chapaPrivateKey.startsWith('CHAPA_TEST_') ? 'test'
    : chapaPrivateKey.startsWith('CHAPA_LIVE_') ? 'live' : null
  if (keyMode && keyMode !== expectedMode) {
    return json({ error: 'Chapa API key environment does not match CHAPA_MODE' }, 503)
  }
  if (event.mode && String(event.mode).toLowerCase() !== expectedMode) {
    return json({ error: 'Webhook environment does not match this deployment' }, 401)
  }
  const merchantReference = String(event.merchant_reference ?? '')
  const chapaReference = String(event.chapa_reference ?? '')
  if (!merchantReference) return json({ error: 'Missing merchant reference' }, 400)
  const supabaseUrl = Deno.env.get('SUPABASE_URL')!
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
  const admin = createClient(supabaseUrl, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } })

  if (event.webhook_type === 'payout') {
    const { data: payout, error: payoutError } = await admin.from('platform_payouts')
      .select('id, merchant_reference, amount_minor, status').eq('merchant_reference', merchantReference).maybeSingle()
    if (payoutError || !payout) return json({ error: 'Payout reference not found' }, 404)
    const reference = chapaReference || merchantReference
    const verifyResponse = await fetch(`https://api.chapa.global/v2/payouts/${encodeURIComponent(reference)}/verify`,
      { headers: { Authorization: `Bearer ${chapaPrivateKey}` } })
    const verified = await verifyResponse.json().catch(() => ({}))
    const details = verified?.data
    if (!verifyResponse.ok || verified?.status !== 'success' || !details) {
      console.error('Chapa payout verification is temporarily unavailable')
      return json({ error: 'Chapa payout verification is temporarily unavailable; retry this webhook' }, 503)
    }
    if (String(details.merchant_reference ?? '') !== payout.merchant_reference ||
        String(details.currency ?? '') !== 'ETB' || Number(details.amount) !== Number(payout.amount_minor)) {
      return json({ error: 'Verified payout does not match the stored withdrawal' }, 409)
    }
    const providerStatus = String(details.status ?? '').toUpperCase()
    const mapped: Record<string, string> = {
      SUCCESS: 'succeeded', PENDING: 'pending', FAILED: 'failed',
      REVERSED: 'reversed', BLOCKED: 'blocked', AUTH_NEEDED: 'auth_needed',
      OTP_NEEDED: 'otp_needed', OTP_FAILED: 'otp_failed',
    }
    const mappedStatus = mapped[providerStatus]
    if (!mappedStatus) return json({ received: true, verified: true, status_unmapped: true })
    const { data: payoutResult, error: payoutUpdateError } = await admin.rpc('record_tiqet_platform_payout_result', {
      p_payout_id: payout.id,
      p_status: mappedStatus,
      p_provider_reference: String(details.chapa_reference ?? chapaReference),
      p_provider_service_fee_minor: Number(details.service_fee ?? 0),
      p_provider_payload: {
        chapa_reference: String(details.chapa_reference ?? chapaReference),
        merchant_reference: payout.merchant_reference, status: providerStatus,
        amount_minor: Number(details.amount), currency: String(details.currency ?? ''),
        provider_service_fee_minor: Number(details.service_fee ?? 0),
      },
    })
    if (payoutUpdateError) {
      console.error('Could not persist verified Chapa payout status', payoutUpdateError.message)
      return json({ error: 'Could not persist verified payout status' }, 500)
    }
    const payloadHash = await sha256(rawBytes)
    const { error: payoutEventError } = await admin.from('webhook_events').upsert({
      provider: 'chapa_payout', payload_sha256: payloadHash, merchant_reference: merchantReference,
    }, { onConflict: 'provider,payload_sha256', ignoreDuplicates: true })
    if (payoutEventError) return json({ error: 'Could not persist payout webhook receipt' }, 500)
    return json({ received: true, verified: true, payout_status: payoutResult?.status ?? mappedStatus, ignored_conflicting_status: payoutResult?.ignored_conflicting_status === true })
  }

  if (event.webhook_type === 'refund') {
    const eventName = String(event.event ?? '')
    const refundStatus = String(event.status ?? '')
    const originalAmountMinor = Number(event.amount)
    const refundedAmountMinor = Number(event.refunded_amount)
    const currency = String(event.currency ?? '')
    if (!['payment.partially_refunded', 'payment.fully_refunded'].includes(eventName)) {
      return json({ received: true, ignored: true, reason: 'Unsupported refund event' })
    }
    if (!Number.isSafeInteger(originalAmountMinor) || !Number.isSafeInteger(refundedAmountMinor) ||
        originalAmountMinor <= 0 || refundedAmountMinor <= 0 || refundedAmountMinor > originalAmountMinor ||
        currency !== 'ETB' ||
        (eventName === 'payment.fully_refunded' && (refundStatus !== 'fully_refunded' || refundedAmountMinor !== originalAmountMinor)) ||
        (eventName === 'payment.partially_refunded' && (refundStatus !== 'partially_refunded' || refundedAmountMinor >= originalAmountMinor))) {
      return json({ error: 'Invalid refund notification fields' }, 400)
    }
    const payloadHash = await sha256(rawBytes)
    const { data: refundResult, error: refundError } = await admin.rpc('record_chapa_refund_notice', {
      p_merchant_reference: merchantReference, p_payload_sha256: payloadHash,
      p_event_name: eventName, p_provider_status: refundStatus,
      p_original_amount_minor: originalAmountMinor, p_refunded_amount_minor: refundedAmountMinor,
      p_currency: currency, p_provider_payload: event,
    })
    if (refundError) return json({ error: 'Could not persist refund notice for reconciliation' }, 500)
    const { data: reconciliation, error: reconciliationError } = await admin.rpc('reconcile_chapa_refund_notice', {
      p_merchant_reference: merchantReference,
      p_refunded_amount_minor: refundedAmountMinor,
    })
    if (reconciliationError) {
      console.error('Could not reconcile refund webhook with verified refund records', reconciliationError.message)
      return json({ error: 'Refund notice was recorded but payment reconciliation needs retry' }, 503)
    }
    const { data: refundPayment } = await admin.from('payments')
      .select('id, order_id').eq('merchant_reference', merchantReference).maybeSingle()
    if (refundPayment?.id) {
      const { error: refundAuditError } = await admin.from('payment_attempt_events').upsert({
        payment_id: refundPayment.id, order_id: refundPayment.order_id, provider: 'chapa',
        event_type: 'refund_notice', provider_event_reference: chapaReference || merchantReference,
        payload_digest: payloadHash,
        safe_metadata: { event: eventName, refunded_amount_minor: refundedAmountMinor, original_amount_minor: originalAmountMinor },
      }, { onConflict: 'provider,payload_digest', ignoreDuplicates: true })
      if (refundAuditError) console.error('Could not persist refund audit event', refundAuditError.message)
    }
    return json({ received: true, refund_recorded: true, reconciliation, ...refundResult })
  }

  if (event.webhook_type !== 'payment') return json({ received: true, ignored: true })
  const { data: payment, error: paymentError } = await admin.from('payments')
    .select('id, order_id, merchant_reference, amount_minor, currency, status, provider_payload')
    .eq('merchant_reference', merchantReference).maybeSingle()
  if (paymentError || !payment) return json({ error: 'Payment reference not found' }, 404)

  const verificationReference = chapaReference || merchantReference
  const verifyResponse = await fetch(`https://api.chapa.global/v2/payments/${encodeURIComponent(verificationReference)}/verify`,
    { headers: { Authorization: `Bearer ${chapaPrivateKey}` } })
  const verified = await verifyResponse.json().catch(() => ({}))
  const details = verified?.data
  if (!verifyResponse.ok || verified?.status !== 'success' || !details) {
    console.error('Chapa payment verification is temporarily unavailable')
    return json({ error: 'Chapa payment verification is temporarily unavailable; retry this webhook' }, 503)
  }
  const verifiedStatus = String(details.status ?? '').toUpperCase()
  if (verifiedStatus !== 'SUCCESS') {
    if (verifiedStatus === 'FAILED' || verifiedStatus === 'CANCELLED') {
      const failureReason = verifiedStatus.toLowerCase()
      const { error: failError } = await admin.rpc('fail_order_payment', {
        p_order_id: payment.order_id, p_reason: failureReason,
      })
      if (failError) return json({ error: 'Could not persist verified failed-payment state' }, 500)
      const failedPayloadHash = await sha256(rawBytes)
      const { error: failedAttemptEventError } = await admin.from('payment_attempt_events').upsert({
        payment_id: payment.id, order_id: payment.order_id, provider: 'chapa', event_type: 'payment_failed',
        provider_event_reference: chapaReference || merchantReference,
        payload_digest: failedPayloadHash,
        safe_metadata: { provider_status: verifiedStatus, source: 'verified_api' },
      }, { onConflict: 'provider,payload_digest', ignoreDuplicates: true })
      if (failedAttemptEventError) {
        console.error('Could not persist failed-payment audit event', failedAttemptEventError.message)
        return json({ error: 'Could not persist failed payment audit record' }, 500)
      }
      const { error: failureMetadataError } = await admin.from('payments').update({
        failure_code: failureReason, failure_message: 'Chapa verification confirmed payment failure or cancellation.',
      }).eq('id', payment.id)
      if (failureMetadataError) {
        console.error('Could not persist failed-payment details', failureMetadataError.message)
        return json({ error: 'Could not persist failed payment details' }, 500)
      }
    }
    return json({ received: true, verified: true, payment_status: verifiedStatus || 'UNKNOWN' })
  }
  const amount = Number(details.amount)
  const currency = String(details.currency ?? '')
  const verifiedMerchantReference = String(details.merchant_reference ?? '')
  if (!Number.isFinite(amount) || amount !== Number(payment.amount_minor) ||
      currency !== payment.currency || verifiedMerchantReference !== payment.merchant_reference) {
    return json({ error: 'Verified payment does not match the pending order' }, 409)
  }
  const verifiedProviderReference = String(details.chapa_reference ?? chapaReference)
  const { error: completeError } = await admin.rpc('complete_order_payment', {
    p_order_id: payment.order_id, p_provider_reference: verifiedProviderReference,
    p_merchant_reference: verifiedMerchantReference, p_amount_minor: amount, p_currency: currency,
    p_provider_payload: {
      ...(payment.provider_payload ?? {}), verification_status: String(details.status ?? 'SUCCESS'),
      verified_amount_minor: amount, currency, merchant_reference: verifiedMerchantReference,
      chapa_reference: verifiedProviderReference, payment_method: String(details.payment_method ?? ''),
      verified_at: new Date().toISOString(),
    },
  })
  if (completeError) {
    const reviewPayload = {
      verification_status: String(details.status ?? 'UNKNOWN'),
      verified_amount_minor: Number(details.amount ?? 0),
      currency: String(details.currency ?? ''),
      merchant_reference: String(details.merchant_reference ?? ''),
      chapa_reference: verifiedProviderReference,
      manual_review_reason: 'Payment verified but order completion was rejected; operator reconciliation required.',
    }
    const { error: reviewError } = await admin.rpc('flag_order_payment_for_review_and_release_hold', {
      p_order_id: payment.order_id, p_provider_reference: verifiedProviderReference,
      p_provider_payload: { ...((payment.provider_payload ?? {}) as Record<string, unknown>), ...reviewPayload },
    })
    if (reviewError) return json({ error: 'Payment verified but could not be safely moved to reconciliation review' }, 500)
    const payloadHash = await sha256(rawBytes)
    const { error: reviewEventError } = await admin.from('webhook_events').upsert({
      provider: 'chapa', payload_sha256: payloadHash, merchant_reference: merchantReference,
    }, { onConflict: 'provider,payload_sha256', ignoreDuplicates: true })
    if (reviewEventError) return json({ error: 'Could not persist review webhook receipt' }, 500)
    return json({ received: true, verified: true, needs_manual_review: true })
  }

  const { error: genericPaymentUpdateError } = await admin.from('payments').update({
    provider_payment_reference: verifiedProviderReference,
    payment_method: String(details.payment_method ?? ''),
    last_verified_at: new Date().toISOString(),
  }).eq('id', payment.id)
  if (genericPaymentUpdateError) return json({ error: 'Payment completed but provider metadata needs webhook retry' }, 500)

  const payloadHash = await sha256(rawBytes)
  const { error: paymentEventError } = await admin.from('webhook_events').upsert({
    provider: 'chapa', payload_sha256: payloadHash, merchant_reference: merchantReference,
  }, { onConflict: 'provider,payload_sha256', ignoreDuplicates: true })
  if (paymentEventError) return json({ error: 'Could not persist payment webhook receipt' }, 500)
  const { error: successfulAttemptEventError } = await admin.from('payment_attempt_events').upsert({
    payment_id: payment.id, order_id: payment.order_id, provider: 'chapa', event_type: 'payment_succeeded',
    provider_event_reference: verifiedProviderReference, payload_digest: payloadHash,
    safe_metadata: { amount_minor: amount, currency, payment_method: String(details.payment_method ?? '') },
  }, { onConflict: 'provider,payload_digest', ignoreDuplicates: true })
  if (successfulAttemptEventError) return json({ error: 'Could not persist payment audit event' }, 500)
  return json({ received: true, verified: true })
})
