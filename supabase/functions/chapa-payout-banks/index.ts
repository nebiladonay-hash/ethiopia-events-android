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
  const response = await fetch('https://api.chapa.global/v2/payouts/banks?country=ET', { headers: { Authorization: `Bearer ${key}` } })
  const result = await response.json().catch(() => ({}))
  if (!response.ok || result?.status !== 'success' || !Array.isArray(result?.data)) {
    return json({ error: result?.message ?? 'Could not load payout destinations' }, 502)
  }
  const destinations = result.data.filter((b: Record<string, any>) => b.is_active === true).map((b: Record<string, any>) => ({
    name: String(b.bank_name ?? b.bank_slug), slug: String(b.bank_slug), type: String(b.type ?? 'bank'),
    min_amount_minor: b.min_amount ?? null, max_amount_minor: b.max_amount ?? null,
  }))
  return json({ currency: 'ETB', country: 'ET', destinations })
})
