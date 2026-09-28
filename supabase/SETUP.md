# QAVERA Supabase setup

Run these in order. Each SQL file is safe to run more than once.

## 1. Database (SQL Editor → New query → paste → Run)

1. `001_security_and_points.sql`: stops customers editing their points or role, blocks
   direct order inserts, and awards points when an order is marked `delivered`.
2. `002_catalog_flavors_contact.sql`: adds the Assorted / Bites / Slabs / Spreads / LâLI
   products, fixes the checkout function (it failed with "column reference order_number is
   ambiguous"), saves LâLI custom flavours, and creates the `contact_messages` table.

Prices in the products table are what customers are charged. If you change a price on the
website, change it in **Table Editor → product_variants** too.

## 2. Contact form emails

Messages are saved in **Table Editor → contact_messages** as soon as step 1 is done.
To also get each one by email:

1. **Resend account.** Sign up at https://resend.com with the email address that should
   receive the messages. Go to **API Keys → Create API key** and copy it.
2. **Create the function.** In Supabase: **Edge Functions → Deploy a new function → Via
   Editor**. Name it `contact-notify`, replace the code with
   `supabase/functions/contact-notify/index.ts`, and click **Deploy**. Then open the
   function's **Details** tab, turn **off** "Verify JWT" / "Enforce JWT verification", and
   save.
3. **Secrets.** In **Edge Functions → Secrets**, add:
   - `RESEND_API_KEY`: the key from step 1
   - `CONTACT_TO_EMAIL`: the same email you signed up to Resend with
   - `CONTACT_WEBHOOK_SECRET`: any long random text (for example from a password generator)
4. **Webhook.** In **Database → Webhooks → Create a new hook**:
   - Name: `contact-notify`
   - Table: `contact_messages`, Events: **Insert**
   - Type: **Supabase Edge Functions**, function `contact-notify`, method `POST`
   - HTTP Headers: add `x-webhook-secret` with the same value as `CONTACT_WEBHOOK_SECRET`
5. **Test.** Send a message from the Contact Us page. It should show up in the table and
   in your inbox. If no email arrives, check **Edge Functions → contact-notify → Logs**.

Until you verify your own domain in Resend, emails come from `onboarding@resend.dev` and
can only go to your Resend sign-up address. That's fine for notifications to yourself.

## 3. Order emails and the orders page

1. Run `004_admin_orders.sql` (SQL Editor). It makes the account with the email at the bottom
   of the file an admin; change it first if you log in with a different email.
2. **Edge Functions → Deploy a new function → Via Editor**: name `order-notify`, paste
   `supabase/functions/order-notify/index.ts`, deploy, then in its **Settings** turn off
   "Verify JWT" and save. It reuses the secrets from `contact-notify`.
3. **Integrations → Database Webhooks → Webhooks → Create a new hook**:
   - Name `order-notify`, table `orders`, events **Insert** and **Update**
   - Type **Supabase Edge Functions**, function `order-notify`, method `POST`
   - Header `x-webhook-secret` = the same value as `CONTACT_WEBHOOK_SECRET`

Emails sent: new order (customer confirmation + notice to `CONTACT_TO_EMAIL`), out for
delivery, and delivered (with points earned). They come from `orders@qavera.qa`; to change
that, add the secret `ORDERS_FROM_EMAIL`.

Manage orders at **qavera.qa/admin.html** (admins only).

## 4. Managing orders

Use **qavera.qa/admin.html**: each order has buttons for the next step (Confirm → Preparing →
Out for delivery → Delivered) and Cancel. Customers see the status under **My Orders**.

- `delivered` gives the customer points (100 per QAR 1,000 of products).
- `cancelled` returns any points they spent and takes back any points the order earned.
  Don't move a cancelled order back to another status.
