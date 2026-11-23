# JUMAA property subscription billing rollout

This change is prepared on `feature/property-based-subscription-billing`. It is not deployed to the live Supabase project by this pull request.

## Billing behaviour

- A subscription belongs to one property, not the owner's entire account.
- A newly registered property owned by an `owner` or `jumaa_owner` starts its own 30-day trial.
- Adding another property creates a separate trial and billing calendar.
- Unit counts are recalculated from `public.units`; the existing `get_jumaa_monthly_rate` tier schedule remains the source of the monthly price.
- The authenticated caller, owner profile role, and `properties.owner_id` are checked before a Paystack checkout is initialized.
- Existing property credit is deducted from the amount due before checkout.
- Verified payments are settled by one database transaction. The current property fee is consumed first; any overpayment remains as credit on that property's subscription.
- Partial payments remain as property credit and do not extend the paid-through date until a full billing month is funded.
- Landlords and tenants are not permitted to initialize owner subscription payments.
- Repeated Paystack webhooks cannot extend a subscription more than once.
- Successful payment receipts can be shared/saved as PDF from the owner's subscription screen.

## Administrator rescheduling

The JUMAA platform administrator can select one of two modes per property:

- `temporary_grace`: set a temporary deadline while preserving the normal `next_payment_at` and billing anchor.
- `shift_cycle`: move `next_payment_at` and the billing anchor to the new date.

Every action records the original due date, new due date, administrator, reason and timestamp in `subscription_reschedules`. The owner receives an in-app notification and the app dispatches push/email delivery.

## Files changed

- `supabase/migrations/20261123150000_property_subscription_billing.sql`
- `supabase/functions/initialize-subscription-payment/index.ts`
- `supabase/functions/paystack-webhook/index.ts`
- `supabase/functions/create-subscription-payment/index.ts` (legacy unauthenticated path disabled)
- `supabase/functions/send-jumaa-notification/index.ts`
- `supabase/functions/subscription-reminders/index.ts`
- `lib/main.dart`
- `lib/screens/jumaa_owner/jumaa_owner_dashboard.dart`
- `lib/screens/jumaa_owner/jumaa_owner_subscriptions_page.dart`
- `pubspec.yaml`

## Deployment checklist (run only after review)

1. Confirm the target Supabase project and inspect its migration history.
2. Review the migration against the live schema, especially existing `subscriptions`, `subscription_payments`, `profiles`, `properties`, `units`, and `owner_notifications` columns.
3. Apply the migration to a non-production/staging database first.
4. Confirm required Edge Function secrets exist:
   - `PAYSTACK_SECRET_KEY`
   - `SUPABASE_ANON_KEY` (used to validate the caller's access token)
   - `BREVO_API_KEY` and `EMAIL_FROM`
   - `FIREBASE_PROJECT_ID`, `FIREBASE_CLIENT_EMAIL`, `FIREBASE_PRIVATE_KEY`
   - `SUBSCRIPTION_REMINDER_CRON_SECRET`
5. Deploy `initialize-subscription-payment`, `paystack-webhook`, `send-jumaa-notification`, and `subscription-reminders`.
6. Schedule `subscription-reminders` once per day (recommended 06:00 Africa/Nairobi) using Supabase Cron or an external scheduler. The request must include:
   - `Authorization: Bearer <service-role JWT>`
   - `x-subscription-cron-secret: <SUBSCRIPTION_REMINDER_CRON_SECRET>`
   - JSON body `{}`
7. Configure Paystack to deliver `charge.success` webhooks to the deployed `paystack-webhook` function.
8. Run the staging test matrix below before enabling production collection.

## Required staging tests

- Register two properties for the same owner on different dates; verify each has its own 30-day trial and billing calendar.
- Verify a landlord and a tenant cannot initialize subscription checkout.
- Verify an owner cannot pay for a property owned by another account.
- Verify KSh 2,500 against a KSh 2,400 monthly fee produces KSh 2,400 applied and KSh 100 credit.
- Verify KSh 2,300 payment with KSh 100 existing credit settles exactly one KSh 2,400 month.
- Verify a partial payment is retained as credit and leaves the correct outstanding balance.
- Replay the same Paystack webhook; verify no second extension or duplicate payment notification occurs.
- Test both reschedule modes and verify future dates differ as expected.
- Verify 7-, 3-, 1- and 0-day reminders reach in-app, push and email channels; verify retry does not create duplicate in-app notifications.
- Download a PDF receipt and confirm it only appears for verified successful payments.
- Verify each owner's property credit, due date and receipt history remain isolated from their other properties.

## Important limitations before production

- The daily reminder function is included, but its scheduler and secrets must be configured in the target Supabase project.
- The migration backfills a 30-day rollout trial only for eligible existing properties that have no subscription and no subscription payment history. Existing subscription rows and payment history are not reset.
- Existing duplicate subscription rows, if any, must be identified before applying the migration. The payment initializer fails closed if a property has more than one subscription.
- PDF receipts are generated client-side from the verified payment row; this does not yet create a server-hosted immutable PDF artifact.
- No live database, Paystack, or Edge Function deployment is performed by this PR.
