import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.49.1'
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
  const url = Deno.env.get('SUPABASE_URL')
  const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')
  if (!url || !key) return json({ error: 'Payment service is not configured' }, 503)
  const admin = createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } })
  const { data: rows, error } = await admin.from('payment_provider_registry')
    .select('provider, display_name, adapter_status, checkout_enabled, marketplace_split_supported, organiser_payout_supported, payment_methods, activation_notes')
    .order('display_name')
  if (error) return json({ error: 'Could not load payment provider catalogue' }, 500)
  let chapaMethods: unknown[] = []
  const chapaKey = Deno.env.get('CHAPA_PRIVATE_KEY')
  if (chapaKey && (rows ?? []).some((item: any) => item.provider === 'chapa' && item.checkout_enabled)) {
    try {
      const response = await fetch('https://api.chapa.global/v2/payments/methods', { headers: { Authorization: `Bearer ${chapaKey}` } })
      const payload = await response.json().catch(() => ({}))
      if (response.ok && payload?.status === 'success' && Array.isArray(payload?.data)) {
        chapaMethods = payload.data.filter((method: Record<string, any>) =>
          method.can_process_payments === true && method.supported_currencies?.ETB?.countries?.ET?.is_enabled === true
        ).map((method: Record<string, any>) => ({ slug: String(method.slug), name: String(method.name ?? method.slug), mobile_money: Boolean(method.is_mobile_money) }))
      }
    } catch (error) { console.error('Chapa methods lookup failed', error) }
  }
  const providers = (rows ?? []).map((row: any) => ({
    ...row, payment_methods: row.provider === 'chapa' ? chapaMethods : row.payment_methods,
  }))
  return json({ currency: 'ETB', country: 'ET', providers })
})
