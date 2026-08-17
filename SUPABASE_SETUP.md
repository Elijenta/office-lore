# Office Lore — Supabase setup

Status: **done and verified.** This file is now a reference for what was set up, in case you need to reproduce it (new environment, new Supabase project, onboarding someone else to the setup) — not a to-do list.

## What's live

- Project URL: `https://pldhdsopdwmgvuvwdsta.supabase.co` (hardcoded in `index.html`, along with the publishable/anon key — safe to expose in client code, Row Level Security is the real protection layer).
- Schema: [`supabase/0001_schema.sql`](supabase/0001_schema.sql) — tables, RLS policies, XP-ledger triggers, Realtime.
- [`supabase/0003_xp_cleanup_triggers.sql`](supabase/0003_xp_cleanup_triggers.sql) — required companion migration so deleting a nickname/quote/anecdote/counter/beer (or moving a Perfect Pour vote) correctly reverses the XP it granted, instead of leaving it stale.
- [`supabase/0002_seed_demo_data.sql`](supabase/0002_seed_demo_data.sql) — optional example content, not run on the live project.
- [`supabase/0004_abt_dynasty.sql`](supabase/0004_abt_dynasty.sql) — **The Abt Dynasty**: `abt_reigns` table (persisted reign history) + a trigger on `xp_events` that automatically crowns/dethrones based on live Beer XP standings. Nothing in the app ever writes to this table directly — only that trigger does.
- [`supabase/0005_beer_session_editing.sql`](supabase/0005_beer_session_editing.sql) — required for **Edit Session**: broadens Beer Club RLS so any of the 3 users can edit an existing session's date/location/participants/beers/ratings/consumption (not just the original creator/row-owner — a session is a shared group log), and adds a delta-XP trigger so editing a quantity only awards/revokes XP for the difference. This also fixed a latent bug where the original "create session" flow could silently fail to save other participants' scores, since the old owner-only insert policy rejected any row that wasn't the creator's own.
- Auth: **self-service sign-up**, open to anyone with the app's link (no allowlist). Authentication → Providers → Email → "Confirm email" is currently **off**, so new accounts can log in immediately after registering, no email click required.

## Reproducing this from scratch (new project)

1. Create a Supabase project ([supabase.com](https://supabase.com) → New project).
2. SQL Editor → run `0001_schema.sql`, then `0003_xp_cleanup_triggers.sql`, then `0004_abt_dynasty.sql`, then `0005_beer_session_editing.sql`. `0002_seed_demo_data.sql` is optional (edit the 3 placeholder emails near the top first if you use it).
3. Authentication → Providers → Email → turn "Confirm email" off (unless you want people to click a confirmation link before first login).
4. Project Settings → API → copy the Project URL and the publishable/anon key, paste them into the `SUPABASE_URL` / `SUPABASE_ANON_KEY` constants near the top of `index.html`'s `<script>`.
5. Open `index.html`, click "Registreren" on the login screen to create the first account.

## How people get in

There are no pre-created accounts. Anyone with the app's URL clicks **Registreren** on the login screen, sets an email + password, and is in immediately. "Wachtwoord vergeten?" on the login screen handles password resets via Supabase's email flow (needs "Confirm email"-style mail delivery to work, so make sure your Supabase project's SMTP/email sending is functional if you rely on this).
