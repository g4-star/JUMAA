# JUMAA tenant rent collection

## Scope
Rent collection uses its own `rent_payment_records` ledger and is intentionally isolated from `subscription_payments` (JUMAA's platform subscription billing). Rent is owed to the landlord/designated property account, not to JUMAA.

## Current implementation
- Version 1 allows exactly one active collection destination per apartment: either one M-Pesa Paybill, one M-Pesa Till, or one bank account. The owner/landlord selects the destination type and configures only that destination; saving clears the other destination fields.
- The active apartment destination is displayed prominently on every assigned tenant's Pay Rent screen, even before the tenant creates a payment intent.
- Tenant payment intent is authenticated against the Supabase session and resolved from `tenants.auth_user_id`; client-supplied tenant/property/unit IDs are ignored.
- Payment intent creates a unique `JMR-` reference and returns the selected property's instructions. Existing property M-Pesa Paybill/Till settings are copied into the collection-account table by the migration when present.
- Authorized property managers configure the apartment's single destination from the landlord Payments screen. No owner API keys or callback URLs are required in Version 1.
- Tenants can submit the M-Pesa receipt or bank transaction reference; assigned landlords/property owners can reconcile it after checking the actual account statement.
- Monthly rent charges can be generated per active tenant from the assigned unit's `monthly_rent`, using the recorded tenant move-in month to avoid charging before move-in.
- Verified payments are allocated oldest-due-first across monthly charges. Partial payments reduce the oldest balance; excess remains as tenant credit and is applied to later charges.
- Tenants can view monthly charges, paid amounts, outstanding balances, verified rent totals and share a PDF receipt.
- Property managers can view outstanding charges and overdue counts, generate monthly charges, and reject invalid submissions with an auditable reason.
- Verified payment allocation uses restricted service-role-only database RPCs with invoker security; allocation retries do not duplicate charge credits.
- Tenant RLS permits reading only their own rent payment history and their assigned property's active collection instructions.
- Creating an intent never marks rent as paid. Records remain `pending` or `submitted` until an authorized landlord/property owner reconciliation confirms settlement.
- No credentials, passkeys, bank API keys, or service-role secrets belong in Flutter.

## Version 1 payment flow
1. The property owner/assigned landlord selects Paybill, Till, or bank account and saves exactly one destination.
2. Every tenant assigned to that property sees the same active destination in their Pay Rent screen.
3. The tenant makes the transfer in M-Pesa or their bank app, outside JUMAA.
4. The tenant creates a JUMAA payment record and submits the transaction receipt/reference.
5. The owner/landlord checks the actual destination account statement and verifies or rejects the submitted reference.
6. Only verified payments are allocated to rent charges and receipted.

Version 1 is manual payment and reconciliation. It does not send STK Push prompts. Automated multi-merchant STK Push, provider callbacks and bank integrations are explicitly deferred to Version 2.

## Provider / settlement requirements before live payments
A standard M-Pesa STK Push targets the shortcode configured for the Daraja request; it does not automatically split funds to an arbitrary landlord. Direct landlord settlement requires one of:
1. Each landlord/property has an approved Paybill/Till and the Daraja integration is configured/authorized for that shortcode; or
2. An approved payment aggregator supports sub-merchant/direct settlement and provides signed callbacks.

Bank transfer instructions are property-specific. Automated bank confirmation requires a bank/aggregator statement API; until then, bank transfers must be reconciled by an authorized operator and must not be auto-credited from tenant claims.

## Required deployment configuration
- Apply the migration.
- Deploy `rent-payment-intent` with JWT verification enabled.
- Configure one or more active `rent_collection_accounts` rows per property with verified landlord-owned destinations.
- The current account-configuration screen is integrated into the landlord Payments page. Owners can open **Payments → Rent accounting** to choose an owned property; assigned landlords use their landlord Payments screen.
- Apply and test the new monthly charge/receipt migration before enabling the accounting screens.
- Implement and test a Daraja integration for approved landlord-owned shortcodes (or an approved direct-settlement aggregator) before enabling STK Push or automatic M-Pesa verification.
- Configure a bank/aggregator statement API before enabling automatic bank reconciliation.
- Do not mark a payment `verified` based only on a tenant-submitted receipt or transaction code.

## Safety rules
- Never reuse Paystack subscription functions or tables for rent.
- Never expose Daraja credentials or service-role keys to Flutter.
- Enforce unique provider references and idempotent callbacks.
- Only credit rent after independently verified settlement.
- Refunds/reversals must be ledger events; never silently delete or rewrite a verified payment.


## Current limits
- This release does not initiate STK Push and does not automatically confirm bank transfers.
- Manual verification is the only path that marks a rent payment verified. A transaction code entered by a tenant is never sufficient evidence.
- Rent charges are generated by an authorized property manager for a selected month; this release does not yet run a scheduled monthly charge job.
- PDF receipts are shareable records generated from verified payment metadata; they are not tax invoices or independent proof from a payment provider.
- No Supabase migration or Edge Function has been deployed by this change.
