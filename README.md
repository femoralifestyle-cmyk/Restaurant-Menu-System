# My Restaurant — React + Supabase starter

Restaurant name: My Restaurant  
Currency: INR  
Tax: 0%  
Payment modes: cash + online (online gateway webhook still needs provider credentials)

## Apps
- `apps/customer`: mobile-first customer menu, OTP login, cart and table QR order submission.
- `apps/admin`: staff OTP login and order queue/status updates.
- `supabase/migrations`: database schema and secure RPC migrations.
- `supabase/functions/place-order`: authenticated order endpoint.

## Setup
1. Create a Supabase project.
2. In Supabase SQL Editor, apply the initial schema migration and the secure ordering migration from this repository. Review the security notes before production; do not deploy the earlier draft policies unchanged.
3. Enable Phone Auth and configure an SMS provider.
4. Copy `.env.example` to `apps/customer/.env.local` and `apps/admin/.env.local`; fill in the Supabase project URL and publishable/anon key.
5. Run `npm install` at the repository root.
6. Run `npm run dev:customer` or `npm run dev:admin`.

## Required production setup
- Seed a restaurant record with slug `my-restaurant`, settings, categories, products and tables.
- Add owner/admin membership for a verified auth user before using the admin console.
- Generate QR URLs using the table `qr_token`; the current customer app reads the token from `?table=TOKEN` or the final URL path segment.
- Configure a payment provider and verify signed webhooks server-side before enabling online payment.
- Tighten RLS and add dedicated staff/customer policies for all tables. Never expose service-role credentials in browser builds.
- Configure allowed origins instead of wildcard CORS for production.

## Important
This is a runnable starter scaffold, not a deployed or production-certified service. The database migrations and payment workflow require review and integration with your actual Supabase project and gateway credentials. The sample customer checkout currently submits cash orders; online checkout is intentionally not represented as paid until a verified gateway webhook is integrated.
