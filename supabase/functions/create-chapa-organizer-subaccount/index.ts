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

  const { data: existingAccount, error: existingAccountError } = await admin.from('organisation_payment_accounts')
    .select('provider_account_reference, destination_slug, destination_name, account_last4, status')
    .eq('organisation_id', orgId).eq('provider', 'chapa').maybeSingle()
  if (existingAccountError) return json({ error: 'Could not check the existing payout setup. Try again later.' }, 503)
  if (existingAccount) {
    const existingReference = String(existingAccount.provider_account_reference ?? '')
    if (existingAccount.status === 'active' && existingReference && !existingReference.startsWith('pending:')) {
      const { error: syncError } = await admin.from('organisations').update({
        chapa_subaccount_reference: existingReference, payout_method: existingAccount.destination_slug,
        payout_account_last4: existingAccount.account_last4, payout_setup_at: new Date().toISOString(),
      }).eq('id', orgId).is('chapa_subaccount_reference', null)
      if (syncError) return json({ error: 'A Chapa payout account already exists but its organisation record needs support reconciliation.' }, 503)
      return json({ configured: true, bank_name: existingAccount.destination_name ?? existingAccount.destination_slug, account_last4: existingAccount.account_last4 })
    }
    return json({ error: 'A Chapa payout setup is already pending or requires review. Do not submit it again; contact Tiqet support to reconcile the existing request.' }, 409)
  }

  let banksResponse: Response
  let banksJson: Record<string, any>
  try {
    banksResponse = await fetch('https://api.chapa.global/v2/payouts/banks?country=ET', { headers: { Authorization: `Bearer ${key}` } })
    banksJson = await banksResponse.json().catch(() => ({}))
  } catch {
    return json({ error: 'Could not reach Chapa to validate payout destinations. No account was created.' }, 503)
  }
  const bank = Array.isArray(banksJson?.data) ? banksJson.data.find((b: Record<string, any>) => b.bank_slug === bankSlug && b.is_active === true) : null
  if (!banksResponse.ok || !bank) return json({ error: 'That bank or wallet is not currently enabled for Chapa payouts' }, 400)

  // Subaccount creation is not idempotency-cached by Chapa. Claim the unique
  // local organisation/provider row before calling the provider so a lost
  // response cannot cause a second external subaccount on a user retry.
  const pendingReference = 'pending:' + orgId
  const { error: claimError } = await admin.from('organisation_payment_accounts').insert({
    organisation_id: orgId, provider: 'chapa', provider_account_reference: pendingReference,
    destination_slug: bankSlug, destination_name: bank.bank_name ?? body.bank_name ?? bankSlug,
    account_last4: accountNumber.slice(-4), currency: 'ETB', status: 'pending',
    provider_metadata: { creation_status: 'submitting', created_by: 'chapa-subaccount-edge-function' },
    updated_at: new Date().toISOString(),
  })
  if (claimError) return json({ error: 'A payout setup request already exists or could not be reserved. Contact Tiqet support before retrying.' }, 409)

  let response: Response
  let result: Record<string, any>
  try {
    response = await fetch('https://api.chapa.global/v2/subaccounts', {
      method: 'POST',
      headers: { Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        subaccount_name: org.name,
        account: { account_number: accountNumber, account_name: accountName, bank_slug: bankSlug, bank_name: bank.bank_name ?? body.bank_name ?? bankSlug },
        currency: 'ETB', split_type: 'percentage', split_value: 95, is_primary: false,
      }),
    })
    result = await response.json().catch(() => ({}))
  } catch {
    await admin.from('organisation_payment_accounts').update({
      provider_metadata: { creation_status: 'unknown', error: 'Network interruption during subaccount creation; provider acceptance is unknown.' },
      updated_at: new Date().toISOString(),
    }).eq('organisation_id', orgId).eq('provider', 'chapa').eq('provider_account_reference', pendingReference)
    return json({ error: 'Chapa may have created the payout account, but the response was lost. The request is locked for reconciliation. Do not submit it again; contact Tiqet support.' }, 202)
  }

  const reference = String(result?.data?.subaccount_reference ?? '')
  if (!response.ok || result?.status !== 'success' || !reference) {
    const definiteRejection = response.status >= 400 && response.status < 500 &&
      ![408, 409, 425, 429].includes(response.status)
    if (definiteRejection && !reference) {
      await admin.from('organisation_payment_accounts').delete()
        .eq('organisation_id', orgId).eq('provider', 'chapa').eq('provider_account_reference', pendingReference)
      return json({ error: result?.message ?? 'Chapa could not create the organiser payout destination' }, 502)
    }
    await admin.from('organisation_payment_accounts').update({
      provider_account_reference: reference || pendingReference,
      provider_metadata: { creation_status: 'unknown', provider_message: String(result?.message ?? ''), chapa_reference_returned: Boolean(reference) },
      updated_at: new Date().toISOString(),
    }).eq('organisation_id', orgId).eq('provider', 'chapa').eq('provider_account_reference', pendingReference)
    return json({ error: 'Chapa did not return a definitive subaccount result. The setup is locked for reconciliation; do not submit it again.' }, 202)
  }

  const { data: updatedOrg, error: updateError } = await admin.from('organisations').update({
    chapa_subaccount_reference: reference, payout_method: bankSlug,
    payout_account_last4: accountNumber.slice(-4), payout_setup_at: new Date().toISOString(),
  }).eq('id', orgId).is('chapa_subaccount_reference', null).select('id').maybeSingle()
  if (updateError || !updatedOrg) return json({ error: 'Chapa created the destination but Tiqet could not save the organisation record. Do not retry; contact support.' }, 500)

  const { data: activeAccount, error: accountUpdateError } = await admin.from('organisation_payment_accounts').update({
    provider_account_reference: reference, status: 'active', verified_at: new Date().toISOString(),
    provider_metadata: { created_by: 'chapa-subaccount-edge-function', creation_status: 'success' },
    updated_at: new Date().toISOString(),
  }).eq('organisation_id', orgId).eq('provider', 'chapa').eq('provider_account_reference', pendingReference)
    .select('id').maybeSingle()
  if (accountUpdateError || !activeAccount) {
    console.error('Could not activate generic settlement account after Chapa subaccount creation', accountUpdateError?.message ?? 'Pending claim not found')
    return json({ error: 'Chapa created the destination and Tiqet saved its reference, but the provider account record needs support reconciliation.' }, 500)
  }

  return json({ configured: true, bank_name: bank.bank_name ?? bankSlug, account_last4: accountNumber.slice(-4) })
})
