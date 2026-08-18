# Backups Only League — self-hosted setup

This is the self-hosted version of Backups Only League. It saves league data (rosters, scores,
lineups, chat) to a free Supabase database, so it works on any URL — and it supports real login:
each friend gets their own account, edits only their own team, and any number of separate leagues
can share the same deployed site (each with its own commissioner and its own private data).

Four steps: **database → auth → code → hosting**. About 20 minutes total, all free tiers.

## 1. Create the database (Supabase)

1. Go to https://supabase.com, sign up free, and create a new project (pick any name/region).
2. Once it's ready, open the **SQL Editor** (left sidebar) → **New Query**.
3. Paste in the contents of `supabase-schema.sql` (included in this folder) and click **Run**.
   (Upgrading from an older single-league version of this site? Re-run this file — every statement
   is safe to run again, and it sets up the new tables + real-time sync alongside your old data
   without touching it. Your old data stays put in the `league_kv` table and can be imported into
   your new league in step 3 below.)
4. Go to **Project Settings → API**. You'll need two values from this page in step 3:
   - **Project URL**
   - **anon public** key

## 2. Turn on login (Supabase Auth)

This app uses **magic-link email login** — no passwords, Supabase just emails a one-click sign-in
link. It's built into every Supabase project for free.

1. In your Supabase project, go to **Authentication → Providers**, and make sure **Email** is
   enabled (it usually is by default).
2. Go to **Authentication → URL Configuration**. Add your site's URL (the one you'll get in step 4
   below, e.g. `https://your-league.vercel.app`) to **Redirect URLs**. Until you have that URL, you
   can leave this as the default `localhost` and come back to update it after step 4 — magic links
   just won't work correctly until this is set to your real deployed URL.
3. Optional: **Authentication → Email Templates** lets you customize the wording of the login email
   (e.g. change "Magic Link" branding). Not required to get started.

## 3. Configure the code

1. Open `index.html` in a text editor.
2. Near the top of the `<script>` tag, find:
   ```js
   const SUPABASE_URL = 'YOUR_SUPABASE_PROJECT_URL';
   const SUPABASE_ANON_KEY = 'YOUR_SUPABASE_ANON_KEY';
   ```
3. Replace both with the values from step 1.4 above. Save the file.

That's it for the app itself — draft, scoring, lineups, and chat all work like before. The
difference is how editing is gated: instead of a shared PIN, whoever creates a league becomes its
commissioner (verified by their real login), and each friend edits only their own team once they've
joined.

## 4. Put it on GitHub

1. Go to https://github.com, create a free account if you don't have one.
2. Click **New repository**, name it (e.g. `backup-bowl`), leave it empty, click **Create**.
3. Upload `index.html`, `supabase-schema.sql`, and this `README.md` to that repo — either drag-and-drop
   them on the GitHub website ("Add file → Upload files"), or if you're comfortable with git:
   ```bash
   git init
   git add .
   git commit -m "Backups Only League"
   git branch -M main
   git remote add origin https://github.com/YOUR_USERNAME/backup-bowl.git
   git push -u origin main
   ```

## 5. Host it (Vercel)

1. Go to https://vercel.com and sign up free with your GitHub account.
2. Click **Add New → Project**, select your `backup-bowl` repo, and click **Deploy**.
   No build settings needed — it's a static HTML file.
3. Vercel gives you a live URL (like `backup-bowl.vercel.app`) — that's your permanent link.
   Send that to your friends instead of a Claude.ai artifact link.
4. Go back to **Authentication → URL Configuration** in Supabase (step 2 above) and make sure this
   real URL is in the Redirect URLs list — magic links won't log people in correctly until it is.

From now on, any time you push a change to the GitHub repo, Vercel redeploys automatically.

## 6. Create your league

1. Open your new live URL. Log in with your email (you'll get a magic link).
2. Once logged in, name your league — you become its commissioner.
3. If you're upgrading from an older single-league version of this site, you'll see an **"Import
   this site's existing rules, scoring settings, and player pool"** checkbox — check it to carry
   those over automatically. (Teams and picks aren't imported, since without real accounts there's
   no one to own them — set teams up fresh via invites below.)
4. From the **Commissioner** tab, copy your league's invite link and send it to your friends. Each
   one logs in with their own email, picks a team name, and can edit only that team from then on.

Anyone can create their own separate league on this same deployed site — leagues never see each
other's data. The 6-character code in the URL (`?league=ABC123`) is what scopes everything.

## Notes

- **Real per-user permissions, enforced by the database** — not just hidden in the UI. Only a
  league's commissioner can edit its Rules, Scoring, lineup settings, player pool, and Draft
  Settings. Each friend can rename their own team and edit their own draft queue, and nothing else.
  Standings, Rosters, and Rules are viewable by anyone with the link, no login required.
- **Your anon key is public** in the page source — that's expected for Supabase's anon key. Actual
  write permissions come from Postgres Row Level Security policies in `supabase-schema.sql`, not
  from keeping the key secret.
- **Making a draft pick stays open to anyone in the room** (not locked to the team's owner) — same
  spirit as before, since a draft is usually a shared live event with everyone watching together.
- **League size:** 4–10 members per league (a warning shows below 4; 10 is a hard cap).
- **Auto-Fetch from Sleeper** still works the same way — it calls Sleeper's public API directly
  from the browser, no server needed.
