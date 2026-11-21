function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  })
}

Deno.serve(async (req: Request) => {
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405)

  const bytes = new Uint8Array(await req.arrayBuffer())
  if (bytes.byteLength > 64 * 1024) return json({ error: 'Payload too large' }, 413)

  let event: Record<string, unknown>
  try {
    const parsed = JSON.parse(new TextDecoder().decode(bytes))
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
      return json({ error: 'Expected a JSON object' }, 400)
    }
    event = parsed as Record<string, unknown>
  } catch {
    return json({ error: 'Invalid JSON' }, 400)
  }

  const transaction = event.transaction && typeof event.transaction === 'object'
    ? event.transaction as Record<string, unknown>
    : {}

  // Sandbox-only observation endpoint. It intentionally performs no payment,
  // ticket, order, inventory, or settlement writes and does not authenticate
  // callbacks as production financial events.
  console.info('ArifPay sandbox webhook received', {
    session_id: event.sessionId ?? null,
    nonce: event.nonce ?? null,
    transaction_status: event.transactionStatus ?? transaction.transactionStatus ?? null,
    transaction_id: transaction.transactionId ?? null,
    payment_method: event.paymentMethod ?? null,
  })

  return json({ received: true, sandbox_only: true, financial_state_changed: false })
})
