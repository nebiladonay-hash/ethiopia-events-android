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
  const key = Deno.env.get('CHAPA_PRIVATE_KEY')
  const chapaMode = Deno.env.get('CHAPA_MODE')?.toLowerCase()
  if (!key || !['test', 'live'].includes(chapaMode ?? '')) {
    return json({ error: 'Configure CHAPA_PRIVATE_KEY and CHAPA_MODE (test or live) in Supabase Edge Function secrets' }, 503)
  }
  const keyMode = key.startsWith('CHAPA_TEST_') ? 'test' : key.startsWith('CHAPA_LIVE_') ? 'live' : null
  if (keyMode && keyMode !== chapaMode) {
    return json({ error: 'Chapa API key environment does not match CHAPA_MODE' }, 503)
  }
  if (chapaMode === 'live' && Deno.env.get('TIQET_LIVE_MARKETPLACE_APPROVED') !== 'true') {
    return json({ error: 'Live organiser settlement setup is locked until Tiqet has written marketplace approval and merchant activation from Chapa.' }, 403)
  }
  const supabaseUrl = Deno.env.get('SUPABASE_URL')!
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY')!
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
  const userClient = createClient(supabaseUrl, anonKey, { global: { headers: { Authorization: authHeader } }, auth: { persistSession: false } })
  const admin = createClient(supabaseUrl, serviceKey, { auth: { persistSession: false } })
  const { data: auth, error: authError } = await userClient.auth.getUser()
  if (authError || !auth.user) return json({ error: 'Invalid or expired session' }, 401)
  let body: { organisation_id?: string; account_name?: string; account_number?: string; bank_slug?: string; bank_name?: string }
  try { body = await req.json() } catch { return json({ error: 'Invalid JSON body' }, 400) }
  const orgId = body.organisation_id?.trim()
  const accountName = body.account_name?.trim()
  const accountNumber = body.account_number?.trim().replace(/\s+/g, '')
  const bankSlug = body.bank_slug?.trim().toLowerCase()
  if (!orgId || !accountName || accountName.length < 2 || !accountNumber || !/^\d{6,30}$/.test(accountNumber) || !bankSlug) {
    return json({ error: 'Organisation, account holder, account number, and a supported bank or wallet are required' }, 400)
  }
  const { data: org, error: orgError } = await admin.from('organisations')
    .select('id, name, owner_id, status, chapa_subaccount_reference')
    .eq('id', orgId).eq('owner_id', auth.user.id).single()
  if (orgError || !org) return json({ error: 'Organisation not found or not owned by this account' }, 404)
  if (org.status !== 'verified') return json({ error: 'Your organisation must be verified before payout setup' }, 403)
  if (org.chapa_subaccount_reference) return json({ error: 'Payout is already configured. Contact Tiqet support to change the destination.' }, 409)
  const banksResponse = await fetch('https://api.chapa.global/v2/payouts/banks?country=ET', { headers: { Authorization: `Bearer ${key}` } })
  const banksJson = await banksResponse.json().catch(() => ({}))
  const bank = Array.isArray(banksJson?.data) ? banksJson.data.find((b: Record<string, any>) => b.bank_slug === bankSlug && b.is_active === true) : null
  if (!banksResponse.ok || !bank) return json({ error: 'That bank or wallet is not currently enabled for Chapa payouts' }, 400)
  const response = await fetch('https://api.chapa.global/v2/subaccounts', {
    method: 'POST',
    headers: { Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      subaccount_name: org.name,
      account: { account_number: accountNumber, account_name: accountName, bank_slug: bankSlug, bank_name: bank.bank_name ?? body.bank_name ?? bankSlug },
      currency: 'ETB', split_type: 'percentage', split_value: 95, is_primary: false,
    }),
  })
  const result = await response.json().catch(() => ({}))
  const reference = result?.data?.subaccount_reference
  if (!response.ok || result?.status !== 'success' || typeof reference !== 'string' || !reference) {
    return json({ error: result?.message ?? 'Chapa could not create the organiser payout destination' }, 502)
  }
  const { error: updateError } = await admin.from('organisations').update({
    chapa_subaccount_reference: reference, payout_method: bankSlug,
    payout_account_last4: accountNumber.slice(-4), payout_setup_at: new Date().toISOString(),
  }).eq('id', orgId).is('chapa_subaccount_reference', null)
  if (updateError) return json({ error: 'Payout destination was created but could not be saved. Contact Tiqet support before retrying.' }, 500)
  const { error: genericAccountError } = await admin.from('organisation_payment_accounts').upsert({
    organisation_id: orgId, provider: 'chapa', provider_account_reference: reference,
    destination_slug: bankSlug, destination_name: bank.bank_name ?? bankSlug,
    account_last4: accountNumber.slice(-4), currency: 'ETB', status: 'active',
    verified_at: new Date().toISOString(), provider_metadata: { created_by: 'chapa-subaccount-edge-function' },
    updated_at: new Date().toISOString(),
  }, { onConflict: 'organisation_id,provider' })
  if (genericAccountError) {
    console.error('Could not sync generic settlement account', genericAccountError.message)
    return json({ error: 'Chapa created the destination but Tiqet could not finish saving its provider record. Contact support before retrying.' }, 500)
  }
  return json({ configured: true, bank_name: bank.bank_name ?? bankSlug, account_last4: accountNumber.slice(-4) })
})
