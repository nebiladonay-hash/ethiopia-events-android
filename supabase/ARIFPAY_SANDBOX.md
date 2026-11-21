# ArifPay sandbox integration for Tiqet

## Scope and safety

This is an isolated sandbox probe, not a production payment adapter.

- ArifPay's official Sandbox Postman collection explicitly documents the fixed sandbox key `arif-sandbox-portal-key`, base URL `https://gateway.arifpay.org`, the test phone numbers, the test-mode headers, and the sandbox C2B endpoints.
- The probe sends a fixed ETB 10 simulator request only.
- It does not create or update Tiqet orders, payments, tickets, inventory, refunds, settlement ledgers, or payout records.
- It never treats the provider response or callback as proof of a real payment.
- The provider registry must remain disabled for ArifPay checkout until production credentials, live API documentation, marketplace split terms, and organizer settlement behavior are confirmed in writing.

Official reference:
- Sandbox overview: https://developer.arifpay.net/sandbox
- Sandbox Postman collection: https://developer.arifpay.net/postman/ArifPay-Sandbox.postman_collection.json
- Developer documentation: https://developer.arifpay.net/docs

## Edge Functions

### `arifpay-sandbox-smoke-test`

JWT is required and the caller must have the server-managed Auth claim `app_metadata.tiqet_role = platform_owner`.

POST body:

```json
{ "flow": "hosted_session", "sim_mode": "SUCCESS" }
```

Supported values:
- `flow`: `hosted_session` or `telebirr_direct`
- `sim_mode`: `SUCCESS` or `FAIL`

Hosted session uses `POST /api/sandbox/c2b/session`.
Telebirr direct uses `POST /api/sandbox/c2b/telebirr-ussd/direct/transfer`.

The default sandbox key is the fixed public key in ArifPay's Postman collection. If ArifPay supplies a different merchant-specific sandbox key, set it as the Supabase Edge Function secret `ARIFPAY_SANDBOX_KEY`; do not commit private keys.

### `arifpay-sandbox-webhook`

JWT verification is disabled because provider callbacks do not carry a user session. This endpoint is deliberately non-financial: it validates only that the body is JSON, logs a small allow-listed set of fields, returns HTTP 200, and never mutates Tiqet records. Do not reuse it for production webhooks.

## Manual smoke-test sequence

1. Sign in as the Tiqet platform owner and invoke `arifpay-sandbox-smoke-test` with `{"flow":"hosted_session","sim_mode":"SUCCESS"}`.
2. Confirm the result reports `sandbox_only: true`, `live_charges_possible: false`, and `order_created: false`. Session creation is not a successful payment.
3. Invoke the same function with `{"flow":"telebirr_direct","sim_mode":"SUCCESS"}` and then `{"flow":"telebirr_direct","sim_mode":"FAIL"}`.
4. Review Edge Function logs for the sandbox callback and verify that no Tiqet payment/order tables were changed.

## Not yet implemented

Production checkout, production verification, signature-verified production webhooks, subaccount onboarding, split payment configuration, real-time settlements, and organizer payouts are intentionally not implemented here. The public docs navigation advertises advanced features, but the sandbox Postman collection does not demonstrate marketplace split/subaccount operations. Obtain the exact live request schemas and sandbox availability from ArifPay before implementing those paths.
