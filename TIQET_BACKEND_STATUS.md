# Tiqet V7.2 backend status

Last verified against production: 2026-11-08.

## Implemented and deployed
- PostgreSQL schema extension for provider registry, payment-attempt audit, organiser settlements, payout requests, refund review and platform reconciliation.
- Nine production migration records, including function-permission hardening, payment-review/refund safety, provider-agnostic payment core, FK indexes, RLS optimizations and webhook receipt table grant lockdown.
- Nine active Supabase Edge Functions, with deployed source synchronized in `supabase/functions/`.
- Chapa checkout, signed webhook verification, dynamic payment-method discovery, payout destination discovery, organiser subaccount setup and platform withdrawal endpoints.
- Server-side platform-owner checks using non-user-editable Auth `app_metadata.tiqet_role`.
- Android payment-method selection patch staged in `patches/` and applied by the V7.2 build workflow.
- Public table RLS enabled throughout the 22-table public schema.
- Simulated role tests confirmed the authenticated account sees only its own profile, while the anonymous role can query public event/ticket endpoints without access to profile or organiser-private tables.
- Webhook receipt table now grants no privileges to `anon` or `authenticated`; `service_role` has only SELECT, INSERT and UPDATE, verified against PostgreSQL privilege checks.

## Latest advisor verification
- No health lint findings.
- No remaining unindexed foreign-key lint.
- No remaining RLS auth-initplan lint.
- No remaining multiple-permissive-policy lint.
- Remaining notices: 12 internal tables have RLS with no anon/user policy (intentional service-role isolation); 8 authenticated SECURITY DEFINER RPC warnings (user-scoped operations with ownership checks); leaked-password protection is disabled in Supabase Auth.
- 38 unused-index INFO findings are expected while the production database has no event/order/payment workload. Reassess after traffic exists.

## Not production-certified
- Chapa private key/webhook secret and sandbox mode were not confirmed by the connected project tools.
- No Chapa sandbox payment, refund, organiser split or payout has been executed.
- Live marketplace permission and payout authorization are not established.
- ArifPay, FenanPay, SantimPay and YagoutPay are registered disabled slots only.
- Android build must pass GitHub Actions and the resulting APK must be installed/tested before release.
- Migration history baseline for pre-existing core schema files (001–005 in the archive) is not yet reconciled. Do not run a schema push from the archive.

## Safety defaults
- Live checkout requires `TIQET_LIVE_MARKETPLACE_APPROVED=true`.
- Live platform payouts require `TIQET_LIVE_PAYOUTS_ENABLED=true`.
- The webhook validates provider HMAC and then verifies payment/payout server-to-server with Chapa.
- Android uses only public Supabase client configuration. Chapa private key/service role stay server-side.
