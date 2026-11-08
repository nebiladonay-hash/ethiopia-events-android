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
  const authHeader = req.headers.get('Authorization')
  if (!authHeader?.startsWith('Bearer ')) return json({ error: 'Sign-in required' }, 401)
  const ownerId = Deno.env.get('TIQET_OWNER_USER_ID')
  if (!ownerId) return json({ error: 'Owner dashboard is not configured' }, 503)
  const url = Deno.env.get('SUPABASE_URL')!
  const anon = Deno.env.get('SUPABASE_ANON_KEY')!
  const service = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
  const userClient = createClient(url, anon, { global: { headers: { Authorization: authHeader } }, auth: { persistSession: false } })
  const admin = createClient(url, service, { auth: { persistSession: false } })
  const { data: auth, error } = await userClient.auth.getUser()
  if (error || !auth.user) return json({ error: 'Invalid or expired session' }, 401)
  if (auth.user.id !== ownerId) return json({ is_owner: false }, 403)
  const { data: summary, error: summaryError } = await admin.rpc('get_tiqet_platform_revenue_summary')
  if (summaryError || !summary) return json({ error: 'Could not read Tiqet revenue ledger' }, 500)
  return json({
    ...summary,
    is_owner: true,
    note: 'Ledger balance is gross platform revenue before payment-processing fees, payout fees, taxes, refunds, disputes, and operating costs. Chapa may reject a withdrawal if its cleared merchant balance is lower.',
  })
})
