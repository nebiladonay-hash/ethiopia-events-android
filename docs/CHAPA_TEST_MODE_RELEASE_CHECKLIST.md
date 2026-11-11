# TIQET × Chapa — Test Mode and Release Checklist

This checklist is for the **test environment only**. It does not authorize live payment processing, production deployment, or any payout to a real bank account.

## 1. Access required from Chapa

Before testing the marketplace flow, obtain from Chapa:
- A main-merchant Test Mode account and dashboard access.
- A test private API key for that merchant.
- Confirmation of the test merchant reference and webhook configuration.
- Permission to create organiser subaccounts and exercise split payments, refund creation/verification and payout simulations.
- A technical review of TIQET's marketplace flow.

Chapa has said that individual developers may continue in Test Mode while business registration is pending. Live transactions still require the business licence and merchant onboarding.

## 2. Supabase secrets — test project only

Set these using the Supabase Edge Function Secrets interface. Never place secret values in source code, an APK, GitHub files, issue comments or chat.

Required:
- `CHAPA_MODE=test`
- `CHAPA_PRIVATE_KEY=<Chapa test private key>`
- Existing Supabase managed secrets: `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY`

Keep all live approval flags unset or false:
- `TIQET_LIVE_MARKETPLACE_APPROVED`
- `TIQET_LIVE_PAYOUTS_ENABLED`

Chapa confirmed that the API base URL is the same in Test Mode and Live Mode: `https://api.chapa.global`. Do not change the base URL to simulate Test Mode; the API key and server-side mode are the environment boundary.

## 3. Apply backend in a non-production Supabase project

1. Back up the test database and confirm the project ID before making changes.
2. Apply `supabase/migrations/20261110120000_chapa_refund_operations.sql`.
3. Deploy the changed Edge Functions from this branch:
   - `create-chapa-checkout`
   - `chapa-webhook`
   - `create-chapa-organizer-subaccount`
   - `create-platform-payout`
   - `create-chapa-refund`
   - `verify-chapa-refund`
4. Keep the service-role key server-side only. Keep webhook verification enabled.
5. Confirm the provider registry still reports Chapa as the only enabled checkout provider. Other providers remain disabled until their own integration contracts and settlement capabilities have been verified.

Do not apply this migration to production as a substitute for a tested rehearsal. This feature branch has not been deployed to production.

## 4. Minimum sandbox test plan

Use test customer accounts and test organiser payout destinations only. Do not use real customer funds or real bank details.

### A. Payment and ticket issuance
1. Create a verified organiser with a Chapa test subaccount.
2. Create one low-value test event and a ticket type with available inventory.
3. Start checkout and record the TIQET order ID and merchant reference.
4. Complete the provider's documented sandbox payment flow.
5. Confirm that the webhook signature is accepted and TIQET independently verifies the transaction with Chapa.
6. Confirm that exactly one payment becomes successful and exactly the reserved number of ticket entitlements are issued.
7. Replay the same webhook. Confirm there is no duplicate ticket issuance, duplicate ledger credit or payment status regression.

### B. Partial refund
1. Use a separate successful test payment.
2. Request a partial refund with an idempotency key.
3. Confirm that Chapa's create acknowledgement leaves the refund pending.
4. Verify that refund individually with Chapa.
5. Only a verified `SUCCESS` may increase the confirmed refunded total.
6. Replay the webhook and retry the same idempotency key. Confirm there is no duplicate refund operation or over-refund.

### C. Full refund and review
1. Use a new test payment and request a full refund.
2. Confirm that TIQET sends the full-refund request without inventing a partial amount.
3. Verify the individual refund with Chapa.
4. Confirm that the order remains in finance review until ticket entitlements and organiser/platform settlement are reconciled. Do not mark it fully settled just because Chapa accepted the refund request.

### D. Failure and interruption cases
- Temporarily interrupt the verification request and confirm the webhook returns a retryable response.
- Simulate duplicate and out-of-order webhook delivery.
- Simulate an ambiguous refund submission and confirm the same idempotency key is preserved.
- Confirm a provider verification outage does not falsely fail an order or mark a refund successful.
- Confirm a payout verification outage leaves the amount reserved and does not trigger an automatic second transfer.
- Confirm a late pending/failed payout event cannot overwrite a previously verified terminal status; only a verified reversal can move a successful payout to reversed.

Record the Chapa references and the resulting TIQET ledger states for each test.

## 5. Before any live release

All of the following are required:
- Chapa marketplace architecture review completed and written approval received.
- Valid Ethiopian business licence and required onboarding documents accepted by Chapa.
- Live merchant account and live API credentials issued.
- Live settlement/split terms, timing, fees, reversal handling and refund procedures confirmed in writing.
- Production migration rehearsed successfully on a production-like backup.
- Sandbox payment, partial refund, full refund, webhook replay, ambiguous network outcomes and payout reconciliation tests passed.
- Android release build signed with production signing credentials and reviewed.
- Live feature flags enabled deliberately by the platform owner only after all previous gates are satisfied.

**Current release status:** backend code and automated checks are prepared in PR #5, but merchant Test Mode access, real sandbox transaction tests, migration rehearsal and Chapa marketplace review remain outstanding. No production migration, Edge Function deployment or live payment/payout has been performed by this change.
