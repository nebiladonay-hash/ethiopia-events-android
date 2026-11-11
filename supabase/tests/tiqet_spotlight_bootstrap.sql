create extension if not exists pgcrypto;

do $$ begin create role anon nologin; exception when duplicate_object then null; end $$;
do $$ begin create role authenticated nologin; exception when duplicate_object then null; end $$;
do $$ begin create role service_role nologin bypassrls; exception when duplicate_object then null; end $$;

create schema if not exists auth;
create table if not exists auth.users (
  id uuid primary key,
  email text unique
);
create or replace function auth.uid() returns uuid language sql stable as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
$$;
grant usage on schema auth to anon, authenticated, service_role;
grant execute on function auth.uid() to anon, authenticated, service_role;

create schema if not exists storage;
create table if not exists storage.buckets (
  id text primary key,
  name text not null,
  public boolean not null default false,
  file_size_limit bigint,
  allowed_mime_types text[]
);
create table if not exists storage.objects (
  id uuid primary key default gen_random_uuid(),
  bucket_id text not null references storage.buckets(id),
  name text not null,
  owner_id uuid,
  created_at timestamptz not null default now(),
  unique(bucket_id,name)
);
alter table storage.objects enable row level security;
create or replace function storage.foldername(name text) returns text[]
language sql immutable as $$
  select case when position('/' in name) = 0 then array[]::text[] else string_to_array(regexp_replace(name, '/[^/]+$', ''), '/') end
$$;
grant usage on schema storage to anon, authenticated, service_role;
grant select, insert, update, delete on storage.objects to authenticated, service_role;
grant select, insert, update, delete on storage.buckets to service_role;

create type public.event_status as enum ('draft','submitted','published','cancelled');
create type public.organisation_status as enum ('pending','verified','rejected');
create table public.organisations (
  id uuid primary key,
  owner_id uuid not null,
  name text not null,
  status public.organisation_status not null,
  payout_account_last4 text
);
create table public.events (
  id uuid primary key,
  organisation_id uuid not null references public.organisations(id),
  created_by uuid not null,
  title text not null,
  description text not null,
  category text not null,
  starts_at timestamptz not null,
  ends_at timestamptz,
  timezone text not null default 'Africa/Addis_Ababa',
  venue_name text not null,
  address text not null,
  city text not null,
  image_url text,
  status public.event_status not null,
  approval_status text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create table public.ticket_types (
  id uuid primary key,
  event_id uuid not null references public.events(id),
  name text not null,
  description text not null default '',
  price_etb numeric not null,
  quantity_total integer not null default 100,
  quantity_reserved integer not null default 0,
  quantity_sold integer not null default 0,
  sales_start timestamptz,
  sales_end timestamptz,
  per_order_limit integer not null default 10,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.events enable row level security;
alter table public.organisations enable row level security;
alter table public.ticket_types enable row level security;

grant select on public.events, public.organisations, public.ticket_types to authenticated;
grant select on public.events, public.ticket_types to anon;

create policy organisations_read_owner
on public.organisations for select to authenticated
using (owner_id = (select auth.uid()));

create or replace function public.is_tiqet_admin() returns boolean language sql stable as $
  select auth.uid() is not null
$;
create or replace function public.is_tiqet_moderator() returns boolean language sql stable as $
  select auth.uid() is not null
$;
grant usage on schema public to anon, authenticated, service_role;
grant execute on function public.is_tiqet_admin() to authenticated, service_role;
grant execute on function public.is_tiqet_moderator() to authenticated, service_role;
