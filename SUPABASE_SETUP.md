# Office Lore — Supabase setup

Follow these steps in order. Steps 1–4 you do yourself in the Supabase dashboard.
Step 5 is the only thing you need to send back to me.

## 1. Create the Supabase project

Go to [supabase.com](https://supabase.com) → **New project** (free tier is fine). Pick any name/region/password (the DB password isn't used by the app — the app only ever uses the anon key, see step 5).

## 2. Create the 3 accounts

**Authentication → Users → Add user**, three times, once for each of Elien, Nick, and Atti.

- Use **real email addresses** you each actually control — this matters, because "forgot password" only works if the email can be delivered.
- Set a temporary password for each (or use "Send invite email" if you'd rather they set their own).
- You don't need to fill in anything else here — a profile row is created automatically for each account as soon as it exists (via a trigger you're about to install in step 3).

## 3. Run the schema SQL

**SQL Editor → New query.**

1. Paste the entire contents of [`supabase/0001_schema.sql`](supabase/0001_schema.sql) and click **Run**. This creates every table, the RLS policies, the XP-ledger triggers, and turns on Realtime for the relevant tables. Required — the app won't work without this.
2. *(Optional)* If you want some example content to look at immediately instead of a blank app, open [`supabase/0002_seed_demo_data.sql`](supabase/0002_seed_demo_data.sql), replace the 3 placeholder emails near the top (`elien@officelore.app` etc.) with the real emails you used in step 2, paste the whole file into a new SQL Editor query, and run it. Skip this entirely if you'd rather start empty — nothing else depends on it.

## 4. Copy your API credentials

**Project Settings → API.** You need two values:

- **Project URL** (looks like `https://xxxxxxxxxxxx.supabase.co`)
- **anon / public** key (a long `eyJ...` string — **not** the `service_role` key, that one must never be used here)

## 5. Send them to me

Paste the Project URL and anon key back in this chat. I'll drop them into a clearly marked config block near the top of `index.html` and then wire up login, all the data screens, and realtime sync.

---

### What happens after that

Once the credentials are in, I'll:
- Replace the "Who enters the Lore?" screen with a real email+password login (session persists across refresh/devices, plus a "forgot password" flow)
- Connect every screen (nicknames, quotes, anecdotes, counters, beer club, leaderboards, profiles) to the database instead of the in-memory mock data
- Add live sync so an action on one device shows up on the others without a manual refresh
- Test it end-to-end in a browser before handing it back to you

You won't need to touch the SQL again after this unless we add a new feature later.
