# JUMAA tenant rent collection

## Scope
Rent collection uses its own `rent_payment_records` ledger and is intentionally isolated from `subscription_payments` (JUMAA's platform subscription billing). Rent is owed to the landlord/designated property account, not to JUMAA.

## Current implementation
- Property-level collection instructions support landlord-owned M-Pesa Paybill/Till and bank accounts.
- Tenant payment intent is authenticated against the Supabase session and resolved from `tenants.auth_user_id`; client-supplied tenant/property/unit IDs are ignored.
- Payment intent creates a unique `JMR-` reference and returns the selected property's instructions.
- Tenant RLS permits reading only their own rent payment history and their assigned property's active collection instructions.
- Creating an intent never marks rent as paid. Records remain `pending` until a verified provider callback or an authorized reconciliation process confirms settlement.
- No credentials, passkeys, bank API keys, or service-role secrets belong in Flutter.

## Provider / settlement requirements before live payments
A standard M-Pesa STK Push targets the shortcode configured for the Daraja request; it does not automatically split funds to an arbitrary landlord. Direct landlord settlement requires one of:
1. Each landlord/property has an approved Paybill/Till and the Daraja integration is configured/authorized for that shortcode; or
2. An approved payment aggregator supports sub-merchant/direct settlement and provides signed callbacks.

Bank transfer instructions are property-specific. Automated bank confirmation requires a bank/aggregator statement API; until then, bank transfers must be reconciled by an authorized operator and must not be auto-credited from tenant claims.

## Required deployment configuration
- Apply the migration.
- Deploy `rent-payment-intent` with JWT verification enabled.
- Configure one or more active `rent_collection_accounts` rows per property with verified landlord-owned destinations.
- Implement and test signed M-Pesa callback verification and bank reconciliation before enabling automatic rent crediting.
- Do not mark a payment `verified` based only on a tenant-submitted receipt or transaction code.

## Safety rules
- Never reuse Paystack subscription functions or tables for rent.
- Never expose Daraja credentials or service-role keys to Flutter.
- Enforce unique provider references and idempotent callbacks.
- Only credit rent after independently verified settlement.
- Refunds/reversals must be ledger events; never silently delete or rewrite a verified payment.
