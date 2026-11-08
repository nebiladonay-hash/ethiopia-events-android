# Tiqet V7.2 backend status

Last connected verification: 2026-11-08.

## Implemented and deployed
- PostgreSQL schema extension for provider registry, payment audit attempts, organiser settlements and payout requests.
- Chapa payment checkout, webhook verification, payment-method discovery, payout-destination discovery, organiser subaccount setup, platform revenue summary and platform payout endpoints.
- Generic provider router and catalogue.
- Server-side payment review, refund notice, settlement and payout controls.
- Android payment-method selector patch staged in `patches/` and applied during the V7.2 Android build workflow.
- Exact deployed Edge Function source is maintained in `supabase/functions/`.

## Not production-certified
- Chapa private key/webhook secret and mode were not confirmed by the connected project tools.
- No Chapa sandbox payment, refund, organiser split or payout has been executed.
- Live marketplace permission and payout authorization are not established.
- Other providers are registered disabled slots only.
- Android build must pass GitHub Actions and the resulting APK must be installed/tested before release.
- Migration history baseline for pre-existing V1-style/numbered core migrations is not yet reconciled. Do not run an unattended schema push.

## Safety defaults
- Live checkout requires `TIQET_LIVE_MARKETPLACE_APPROVED=true`.
- Live platform payouts require `TIQET_LIVE_PAYOUTS_ENABLED=true`.
- The webhook validates provider HMAC and then verifies payment/payout through Chapa server-to-server.
- App client uses only public Supabase configuration. Chapa private key/service role stay server-side.
