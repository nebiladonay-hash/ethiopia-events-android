create role service_role nologin;
create role anon nologin;
create role authenticated nologin;
create schema if not exists auth;
create or replace function auth.jwt() returns jsonb
language sql stable
as $$ select coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb) $$;
grant usage on schema auth to service_role;
grant execute on function auth.jwt() to service_role;

create table public.organiser_payout_requests (
  id uuid primary key,
  organisation_id uuid not null,
  requested_by uuid not null,
  provider text not null,
  amount_minor bigint not null check (amount_minor >= 100),
  currency text not null default 'ETB' check (currency = 'ETB'),
  status text not null default 'requested' check (status in ('requested','approved','processing','paid','rejected','failed','reversed')),
  idempotency_key text not null unique,
  provider_reference text,
  operator_note text,
  reviewed_by uuid,
  reviewed_at timestamptz,
  completed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create table public.organiser_settlement_ledger (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null,
  order_id uuid,
  provider text not null,
  entry_type text not null check (entry_type in ('order_settlement','refund_adjustment','manual_adjustment','payout_debit','payout_reversal')),
  amount_minor bigint not null check (amount_minor <> 0),
  currency text not null default 'ETB' check (currency = 'ETB'),
  idempotency_key text not null unique,
  reference text,
  description text not null default '',
  created_at timestamptz not null default now()
);

grant select on public.organiser_payout_requests, public.organiser_settlement_ledger to service_role;
