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
- `20261108141944_lock_down_webhook_event_table_grants`
- `20261110051948_tiqet_control_staff_roles_and_review_workflow`
- `20261110052005_tiqet_control_staff_directory_and_audit_access`
- `20261110052251_tiqet_control_user_search`
- `20261110052734_tiqet_control_finance_monitoring`
- `20261110053407_tiqet_control_user_moderation`
- `20261110054513_tiqet_trusted_organiser_auto_publish_policy`

The remote schema contains 24 public tables; all observed public tables have RLS enabled. Internal accounting/provider/webhook tables are service-role-only. The production migration history does **not** yet represent the older baseline schema files in the V7.1 archive. Do not run `supabase db push` from the archive until the baseline is reconciled. The GitHub backend workflow is currently a package/source verification workflow only and does not push schema changes.

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


## Direct verification — 8 November 2026

The Supabase connector was used to inspect the live project after the latest deployments:

- Project status: `ACTIVE_HEALTHY` (PostgreSQL 17.11).
- Remote migration history: 9 entries, including the webhook-grants migration listed above.
- Edge Functions: all nine expected functions are `ACTIVE`; JWT verification is enabled for all except `chapa-webhook`, which validates the provider HMAC signature itself.
- Public tables inspected: all 22 have RLS enabled.
- Internal payment/accounting/webhook tables have no anon/authenticated table grants; they are service-role-only. No-policy advisor notices on these tables are intentional deny-by-default protections.
- Payment provider registry: Chapa is the only enabled executable adapter; ArifPay, FenanPay, SantimPay and YagoutPay are disabled with `contract_required` state.
- Current test database has one profile and no organisations, events, ticket types, orders, payments, tickets, provider accounts, settlement entries or payout requests.
- Platform revenue summary RPC returned ETB 0.00 available, as expected for an empty test/production database.

Security advisor notices remain for authenticated-only SECURITY DEFINER RPCs. Their current definitions check `auth.uid()` and apply event/organisation ownership or staff assignment checks before accessing protected rows. They were retained because these RPCs perform transactional writes that the clients cannot perform directly under table grants and RLS. Leaked-password protection remains disabled in Auth and should be enabled in Authentication → Settings → Password Security; it is a project setting and was not changed by SQL.

No customer payment, payout, refund, or provider settlement has been performed. Chapa credentials and merchant approval still need to be confirmed before sandbox/live payment testing.

## Follow-up hardening — 8 November 2026

- The deployed `chapa-webhook` function is version 2. Failed-payment audit rows now include the SHA-256 digest of the exact webhook body and use the provider+digest uniqueness key, so repeated signed failure notifications do not create duplicate audit rows. Failure metadata persistence errors return a retryable 500 response.
- The Chapa V2 split API was cross-checked against the provider's current docs: percentage split values are whole percentages (1–100), while flat split values are integer minor units. Tiqet stores the organiser net as minor units and overrides the subaccount default with a per-payment flat amount.
- A rollback-only database smoke test exercised event submission, paid-ticket hold/inventory reservation, free-ticket claim, ticket issuance, check-in, and duplicate check-in rejection. A separate rollback-only test exercised organiser settlement balance/history and idempotent payout-request queueing. All temporary QA rows were rolled back and production data counts remain zero for organisations, events, orders, payments, tickets, settlement entries and payout requests.
- The platform revenue RPC currently reports ETB 0.00 available, consistent with the empty production data set. No payment, refund or payout has been sent.
- Storage has one private `event-images` bucket with no Storage RLS policies and zero objects. Do not enable broad public writes; implement organiser/event-scoped upload and approved-event read policies together with the corresponding app upload flow before relying on event-image uploads.


## Tiqet Control — staff administration and review workflow (10 November 2026)

The live project now includes the initial secured backend for the separate **Tiqet Control** companion app.

- `tiqet_staff_roles` stores one server-managed staff role per user: `moderator`, `admin`, or `super_admin`. It has RLS enabled and no direct client table grants.
- `is_tiqet_moderator()`, `is_tiqet_admin()`, and `is_tiqet_super_admin()` are SECURITY DEFINER helper functions with an empty search path. Each returns only the calling user's own role capability.
- Moderators and administrators can read submitted event records through a dedicated RLS policy. Staff can read organiser applications; the organiser's private account data remains subject to normal profile policies.
- `review_event_submission` lets moderators/admins approve, reject, or request changes. Approval publishes the event; rejection returns it to draft with a reviewer note. Organisers can edit pending/rejected drafts but cannot set an event to approved or published themselves.
- `submit_event_for_review` was corrected to reset reviewer fields and set `approval_status='pending'` when an organiser resubmits a rejected draft.
- `review_organiser_application` is admin/super-admin only and supports approve, reject, and request-info decisions.
- `tiqet_admin_audit_log` records staff assignments/revocations and organiser/event review actions. It has RLS enabled and no direct client table grants.
- `get_tiqet_control_overview`, `get_tiqet_staff_directory`, `search_tiqet_users`, and `get_tiqet_admin_audit_log` provide narrowly scoped dashboard reads. Staff assignment/revocation RPCs check the caller's super-admin role and prevent removal of the final super-admin.

The known founder account was granted the first `super_admin` role directly in the live project. Its email/UUID are intentionally not hardcoded in public source control. For another environment, bootstrap the first super-admin out-of-band using the trusted account UUID, then manage subsequent staff through the protected RPCs.

### Verification completed

A rollback-only SQL smoke test authenticated as the bootstrapped super-admin, approved a temporary organiser application, approved a temporary event, read the dashboard overview, and retrieved the staff directory. The transaction was rolled back. A follow-up count check confirmed that no test organisations or events remained; the only persistent staff role is the founder super-admin, and the only persistent audit entry is the initial role bootstrap.

No separate Tiqet Control Android APK has been built yet. This work establishes its backend contract and permissions. The companion app UI and build pipeline remain the next implementation phase.


## Tiqet Control companion app

The separate Android companion source lives under `tiqet-control-android/` on the `tiqet-control-v1` branch. It uses the same Supabase project and customer Auth accounts; access is enforced by the backend staff-role records, not by a client-side role selector.

The initial Control build includes:
- Email/password sign-in followed by a server-side `get_tiqet_control_overview` authorization check.
- Role-aware Overview, pending Organiser Applications, pending Event Submissions, Staff Access (super-admin only), Activity Log (admin only), and Finance (admin only, read-only).
- Organiser approve/reject/request-info actions.
- Event approve/reject/request-changes actions.
- Super-admin-only staff user lookup, role assignment and revocation.

The app uses only the public Supabase URL and publishable key in the Android client. It does not include the service-role key or database password. All privileged review actions call SECURITY DEFINER RPCs which enforce the role on the server.

Build workflow:
- Branch: `tiqet-control-v1`
- Workflow: `.github/workflows/build-tiqet-control.yml`
- Artifact name: `tiqet-control-debug-apk`

The current companion-app source is an initial functional control MVP. Account search, temporary sign-in suspension/restoration, and moderation history are now implemented. Staff-device session management, encrypted local session persistence and release signing are not implemented yet. Finance remains read-only; it does not initiate refunds or payouts.


### Finance monitoring RPC

- `get_tiqet_finance_dashboard(p_limit)` is restricted to authenticated Tiqet admins.
- Returns aggregated paid-order/payment-review counts, gross/adjusted/net platform revenue, open payout counts, recent payment records, refund alerts, platform payout summaries and organiser payout request summaries.
- Full bank account numbers and raw provider payloads are not returned. Platform payout destinations are masked to bank name and last four digits.
- The Control app uses this endpoint for read-only financial monitoring. It does not initiate refunds, approve/execute payouts or move money.
- A rollback-only SQL smoke test called the RPC as the bootstrapped super-admin; it returned the expected zero-value / empty result for the empty database.


### User moderation and account suspension

- `tiqet_user_moderation_log` stores actor, target, duration, reason, status, provider/Auth expiry and outcome for each account suspension/restoration attempt. The table is RLS-enabled and service-role-only.
- `search_tiqet_users` is admin-only and returns basic profile data, last sign-in timestamp, current Auth ban expiry and staff-role marker.
- `get_tiqet_user_moderation_history` is admin-only and returns a user's moderation history.
- The `tiqet-admin-user-action` Edge Function performs Auth Admin suspension/restoration. It requires a valid JWT and independently verifies the caller's Tiqet admin role.
- The endpoint blocks self-suspension, super-admin targets and all staff-role targets. Staff access changes remain a separate super-admin operation.
- Supported temporary bans: 24 hours, 7 days and 30 days. Restore clears the ban.
- A temporary Auth ban blocks new sign-ins during the ban period; it does not immediately invalidate already-issued access tokens. Backend authorization must remain enforced on sensitive actions.
- No user has been suspended or restored as part of development/testing.


### Build and deployment verification — 10 November 2026

- The initial Control Android build completed successfully on the `tiqet-control-v1` branch with Android SDK 37.2 and Gradle 9.6.0.
- The build artifact is `tiqet-control-debug-apk` from GitHub Actions run `42762769299`.
- The account-moderation Edge Function `tiqet-admin-user-action` is deployed and ACTIVE in TIqet-production with JWT verification enabled.
- The moderation migration has been applied in production; the moderation history table is empty and no account was suspended or restored as a development test.
- The latest Account Moderation UI/API changes trigger a fresh Android build. Do not distribute that newer build until its CI artifact succeeds and is device-smoke-tested.


### Trust-based event publishing and review overrides

- Organizer verification remains an administrator-controlled process. An unverified/new organizer cannot publish paid events.
- Verified organizers default to manual event review. Admins may explicitly grant auto-publishing through the verified-organizer controls in Tiqet Control, with a mandatory 5–500 character reason and audit entry.
- For a trusted organizer, `submit_event_for_review` publishes a new unflagged event and records the automatic publication in the admin audit log.
- Moderators can flag an already-published event with a reason. It is immediately moved from public `published/approved` state to `submitted/pending` for review.
- A rejected/request-changes event retains an active review flag. Even if its organizer is trusted, resubmitting that event routes back to manual review. Only a later moderator approval resolves the flag.
- Trust and event-flag records are private server-managed tables (RLS enabled; no direct client table grants). All trust changes and event flags are audited.
- Rollback-only smoke test passed: trusted new event auto-published; published-event flag returned it to the review queue; request-changes returned it to draft; resubmission remained pending because the active flag persisted. Test transaction rolled back and left no test event or organizer.
