-- Disposable PostgreSQL test schema.
-- Column names and relevant types mirror the live TIQET payments/orders schema.
-- This file is only used by the GitHub Actions PostgreSQL service, never production.

CREATE EXTENSION IF NOT EXISTS pgcrypto;

DO $$
BEGIN
  CREATE ROLE anon NOLOGIN;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$
BEGIN
  CREATE ROLE authenticated NOLOGIN;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$
BEGIN
  CREATE ROLE service_role NOLOGIN BYPASSRLS;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

CREATE SCHEMA IF NOT EXISTS auth;

CREATE OR REPLACE FUNCTION auth.uid()
RETURNS uuid
LANGUAGE sql
STABLE
AS $$
  SELECT nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
$$;

CREATE OR REPLACE FUNCTION auth.role()
RETURNS text
LANGUAGE sql
STABLE
AS 'SELECT nullif(current_setting(''request.jwt.claim.role'', true), '''')';

CREATE OR REPLACE FUNCTION auth.jwt()
RETURNS jsonb
LANGUAGE sql
STABLE
AS 'SELECT jsonb_build_object(''sub'', nullif(current_setting(''request.jwt.claim.sub'', true), ''''), ''role'', nullif(current_setting(''request.jwt.claim.role'', true), ''''))';
CREATE TYPE public.order_status AS ENUM (
  'payment_pending',
  'paid',
  'payment_failed',
  'payment_review',
  'expired',
  'cancelled',
  'refunded'
);

CREATE TABLE public.orders (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  status public.order_status NOT NULL DEFAULT 'payment_pending',
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.payments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL UNIQUE REFERENCES public.orders(id),
  provider text NOT NULL DEFAULT 'chapa',
  merchant_reference text NOT NULL UNIQUE,
  provider_reference text,
  amount_minor bigint NOT NULL CHECK (amount_minor > 0),
  currency text NOT NULL DEFAULT 'ETB' CHECK (currency = 'ETB'),
  status text NOT NULL DEFAULT 'initiated'
    CHECK (status IN ('initiated','pending','succeeded','failed','review','cancelled','refunded')),
  refunded_amount_minor bigint NOT NULL DEFAULT 0 CHECK (refunded_amount_minor >= 0),
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- Minimal test-only administrator predicate. A non-null authenticated user is
-- considered an administrator in this isolated database.
CREATE OR REPLACE FUNCTION public.is_tiqet_admin()
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
  SELECT auth.uid() IS NOT NULL
$$;

GRANT USAGE ON SCHEMA public, auth TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION auth.uid() TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION auth.role() TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION auth.jwt() TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.is_tiqet_admin() TO anon, authenticated, service_role;
