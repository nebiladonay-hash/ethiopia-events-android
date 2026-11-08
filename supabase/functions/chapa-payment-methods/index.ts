const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'GET, OPTIONS',
}
function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
}
Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'GET') return json({ error: 'Method not allowed' }, 405)
  const key = Deno.env.get('CHAPA_PRIVATE_KEY')
  if (!key) return json({ error: 'Payment provider is not configured' }, 503)
  const response = await fetch('https://api.chapa.global/v2/payments/methods', { headers: { Authorization: `Bearer ${key}` } })
  const result = await response.json().catch(() => ({}))
  if (!response.ok || result?.status !== 'success' || !Array.isArray(result?.data)) {
    return json({ error: result?.message ?? 'Could not load payment methods' }, 502)
  }
  const methods = result.data.filter((m: Record<string, any>) =>
    m.can_process_payments === true && m.supported_currencies?.ETB?.countries?.ET?.is_enabled === true,
  ).map((m: Record<string, any>) => ({
    name: String(m.name ?? m.slug), slug: String(m.slug), is_mobile_money: Boolean(m.is_mobile_money),
    min_amount_minor: m.supported_currencies?.ETB?.countries?.ET?.min_amount ?? null,
    max_amount_minor: m.supported_currencies?.ETB?.countries?.ET?.max_amount ?? null,
  }))
  return json({ currency: 'ETB', country: 'ET', methods })
})
