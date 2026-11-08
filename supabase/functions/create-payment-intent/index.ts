import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.49.1'
import { PROVIDER_CAPABILITIES } from '../_shared/provider-catalog.ts'
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
  let body: { provider?: string; ticket_type_id?: string; quantity?: number; payment_method?: string }
  try { body = await req.json() } catch { return json({ error: 'Invalid JSON body' }, 400) }
  const provider = (body.provider ?? 'chapa').trim().toLowerCase()
  const capability = PROVIDER_CAPABILITIES.find((item) => item.provider === provider)
  if (!capability) return json({ error: 'Unsupported payment provider', available_providers: ['chapa'] }, 400)
  const { data: providerState, error: providerError } = await admin.from('payment_provider_registry')
    .select('adapter_status, checkout_enabled, activation_notes')
    .eq('provider', provider).maybeSingle()
  if (providerError || !providerState) return json({ error: 'Payment provider registry is not installed. Apply migration 005.' }, 503)
  if (!providerState.checkout_enabled || providerState.adapter_status !== 'ready') {
    return json({ error: `${capability.name} is not activated for Tiqet checkout yet.`, provider,
      status: providerState.adapter_status, next_step: providerState.activation_notes }, 409)
  }
  if (!body.ticket_type_id || !Number.isInteger(body.quantity) || (body.quantity ?? 0) < 1 || (body.quantity ?? 0) > 10) {
    return json({ error: 'ticket_type_id and quantity from 1 to 10 are required' }, 400)
  }
  if (provider === 'chapa') {
    const response = await fetch(`${supabaseUrl}/functions/v1/create-chapa-checkout`, {
      method: 'POST',
      headers: { Authorization: authorization, apikey: anonKey, 'Content-Type': 'application/json' },
      body: JSON.stringify({ ticket_type_id: body.ticket_type_id, quantity: body.quantity, payment_method: body.payment_method }),
    })
    const responseText = await response.text()
    return new Response(responseText, { status: response.status,
      headers: { ...corsHeaders, 'Content-Type': response.headers.get('Content-Type') ?? 'application/json' } })
  }
  return json({ error: 'No executable adapter is installed for this provider.' }, 501)
})
