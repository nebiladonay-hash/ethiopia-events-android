# Tiqet Supabase backend

This directory is the reviewed source-of-truth for Tiqet Edge Functions and incremental production migrations committed from the connected Supabase project.

## Production target

- Project: `TIqet-production`
- Project ref: `ebrrdmxyoioefoprtict`
- Region: `eu-west-2`
- Database: PostgreSQL 17
- Project status at last verification: healthy

## Remote database state

The existing Tiqet core schema was already present before this connected production migration pass. The backend pass added and verified these migration records in Supabase:

- `20261108131058_harden_public_rpc_execute_grants`
- `20261108131548_payment_review_refund_safety`
- `20261108131602_provider_balance_aware_payout_reserve`
- `20261108131724_provider_agnostic_payment_core`
- `20261108133704_index_uncovered_foreign_keys`
- `20261108133821_optimize_rls_auth_function_calls`
- `20261108133852_merge_overlapping_public_read_policies`
- `20261108134159_split_anon_public_read_rls_policies`

The remote schema contains 22 public tables; all observed public tables had RLS enabled. Internal accounting/provider/webhook tables are service-role-only. The production migration history does **not** yet represent the older baseline schema files in the V7.1 archive. Do not run `supabase db push` from the archive until the baseline is reconciled. The GitHub backend workflow is currently a package/source verification workflow only and does not push schema changes.

## Active Edge Functions

All nine functions were active at last verification:

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

Chapa is the only executable checkout adapter. Its registry entry has checkout/split/payout capabilities enabled in the database, but credentials and merchant permissions remain separate prerequisites.

ArifPay, FenanPay, SantimPay, and YagoutPay remain `contract_required` and disabled. Their provider slots are not claims of completed integrations.

## Required Edge Function secrets

Configure these privately in Supabase Edge Function secrets before sandbox testing:

- `CHAPA_PRIVATE_KEY`
- `CHAPA_WEBHOOK_SECRET`
- `CHAPA_MODE=test` for sandbox testing (or `live` only after written approval)
- `TIQET_LIVE_MARKETPLACE_APPROVED=true` only after Chapa confirms Tiqet's marketplace/split permission in writing
- `TIQET_LIVE_PAYOUTS_ENABLED=true` only after platform payout permission and operational controls are approved

Supabase's standard Edge Function environment values (`SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY`) are platform-provided. Do not put private keys or the service-role key in the Android APK, repository variables, or source files.

The existing single Tiqet Auth account was granted server-managed `app_metadata.tiqet_role=platform_owner`. Platform-owner Edge Functions check this non-user-editable Auth metadata before returning the platform revenue summary or accepting platform payout requests.

## Payment and RLS safety

- A client redirect is never treated as proof of payment.
- The webhook verifies its HMAC signature and calls Chapa's server-side payment/payout verification before recording provider success.
- Payment reference, amount in minor units, and currency must match the stored order.
- Refund webhooks are placed into manual reconciliation. Partial/full refunds are not finalized until an operator records the provider-confirmed adjustment.
- Payout requests are idempotent, reserve against the revenue ledger and a fresh Chapa available balance, and remain pending until a verified final provider status is received.
- Live payment and live payout paths fail closed unless the approval flags are explicitly configured.
- Anonymous/public event and ticket reads are isolated from authenticated organiser-owned draft reads; simulated `anon` and `authenticated` role queries passed after policy separation.

## Security and performance review

- No public-table RLS-disabled findings.
- No remaining unindexed-FK lint.
- No remaining `auth.uid()` per-row policy-initplan lint.
- No remaining overlapping permissive SELECT-policy lint.
- Remaining notices include internal RLS-protected tables with no anon/user policies (intentional), authenticated-only SECURITY DEFINER app RPCs that perform ownership checks, and leaked-password protection disabled in Auth.
- Unused-index INFO findings are expected while the production database has almost no event/order/payment workload. Reassess after traffic exists.

## Current verification boundary

Database migrations and Edge Function deployments were verified. No Chapa sandbox transaction, actual payout, live payment, refund, or live provider settlement has been performed in this pass. The next required step is configuring sandbox credentials privately and running end-to-end sandbox tests.
