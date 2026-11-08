# Tiqet Supabase backend

This directory is the reviewed source-of-truth for the Tiqet Edge Functions. The active production functions were deployed through the connected Supabase project and their exact deployed source was synced into this repository.

## Production target

- Project: `TIqet-production`
- Project ref: `ebrrdmxyoioefoprtict`
- Region: `eu-west-2`
- Database: PostgreSQL 17
- Project status at last verification: healthy

## Remote database state

The existing Tiqet core schema was already present before this connected production migration pass. The backend pass added and verified the following migration records in Supabase:

- `20261108131058_harden_public_rpc_execute_grants`
- `20261108131548_payment_review_refund_safety`
- `20261108131602_provider_balance_aware_payout_reserve`
- `20261108131724_provider_agnostic_payment_core`

The remote schema contains 22 public tables; all observed public tables had RLS enabled. Four tables that store internal accounting, provider, webhook, or reconciliation records are deliberately restricted to service-role operations. The production migration history does **not** yet represent the older baseline schema files in this package. Do not run `supabase db push` from this package until a proper baseline/reconciliation is prepared and reviewed. The GitHub backend workflow is currently a package/source verification workflow only and does not push schema changes.

## Active Edge Functions

All nine functions were confirmed active after deployment:

- `create-payment-intent`
- `create-chapa-checkout`
- `chapa-webhook`
- `chapa-payment-methods`
- `chapa-payout-banks`
- `create-chapa-organizer-subaccount`
- `create-platform-payout`
- `platform-revenue-summary`
- `payment-provider-catalog`

All functions except the provider webhook require a valid user JWT. The Chapa webhook has JWT verification disabled at the gateway because it validates the provider HMAC signature on the exact raw request body itself.

## Provider activation

Chapa is the only executable checkout adapter. Its registry entry has checkout/split/payout capabilities enabled in the database, but credentials and merchant permissions are separate prerequisites.

ArifPay, FenanPay, SantimPay, and YagoutPay remain `contract_required` and disabled. Their provider slots are not claims of completed integrations.

## Required Edge Function secrets

Configure these privately in Supabase Edge Function secrets before sandbox testing:

- `CHAPA_PRIVATE_KEY`
- `CHAPA_WEBHOOK_SECRET`
- `CHAPA_MODE=test` for sandbox testing (or `live` only after written approval)
- `TIQET_LIVE_MARKETPLACE_APPROVED=true` only after Chapa confirms Tiqet's marketplace/split permission in writing
- `TIQET_LIVE_PAYOUTS_ENABLED=true` only after platform payout permission and operational controls are approved

Supabase's standard Edge Function environment values (`SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY`) are platform-provided. Do not put private keys or the service-role key in the Android APK, repository variables, or source files.

The existing single Tiqet owner Auth account was marked with server-managed `app_metadata.tiqet_role=platform_owner`; platform-owner Edge Functions check this non-user-editable claim through Auth before returning revenue or accepting a withdrawal request.

## Payment safety

- A client redirect is never treated as proof of payment.
- The webhook verifies its HMAC signature and calls Chapa's server-side payment/payout verification before recording provider success.
- Payment references, amount in minor units, and currency must match the stored order.
- Refund webhooks are placed into manual reconciliation. Partial/full refunds are not finalized until an operator records the provider-confirmed adjustment.
- Payout requests are idempotent, reserve against the revenue ledger and fresh Chapa available balance, and remain pending until a verified final provider status is received.
- Live payment and live payout paths fail closed unless the approval flags are explicitly configured.

## Current verification boundary

Database migrations and Edge Function deployments were verified. No Chapa sandbox transaction, actual payout, live payment, refund, or live provider settlement has been performed in this pass. The next required step is configuring sandbox credentials privately and running end-to-end sandbox tests.
