# Backups Only League — self-hosted setup

This is the self-hosted version of Backups Only League. It's the same site you've been using, with one
change under the hood: instead of relying on Claude.ai's built-in storage, it saves league data
(rosters, scores, lineups, chat) to a free Supabase database, so it works on any URL.

Three steps: **database → code → hosting**. About 15 minutes total, all free tiers.

## 1. Create the database (Supabase)

1. Go to https://supabase.com, sign up free, and create a new project (pick any name/region).
2. Once it's ready, open the **SQL Editor** (left sidebar) → **New Query**.
3. Paste in the contents of `supabase-schema.sql` (included in this folder) and click **Run**.
4. Go to **Project Settings → API**. You'll need two values from this page in the next step:
   - **Project URL**
   - **anon public** key

## 2. Configure the code

1. Open `index.html` in a text editor.
2. Near the top of the `<script>` tag, find:
   ```js
   const SUPABASE_URL = 'YOUR_SUPABASE_PROJECT_URL';
   const SUPABASE_ANON_KEY = 'YOUR_SUPABASE_ANON_KEY';
   ```
3. Replace both with the values from step 1.4 above. Save the file.

That's it for the app itself — everything else (draft, scoring, lineups, commissioner PIN, chat)
works exactly like it did before.

## 3. Put it on GitHub

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

## 4. Host it (Vercel)

1. Go to https://vercel.com and sign up free with your GitHub account.
2. Click **Add New → Project**, select your `backup-bowl` repo, and click **Deploy**.
   No build settings needed — it's a static HTML file.
3. Vercel gives you a live URL (like `backup-bowl.vercel.app`) — that's your permanent link.
   Send that to your friends instead of a Claude.ai artifact link.

From now on, any time you push a change to the GitHub repo, Vercel redeploys automatically.

## Notes

- **No logins.** Like before, anyone with the link can edit shared data — same honor-system
  design, just now the commissioner PIN is the only thing gating Rules and Scoring Weights.
- **Your anon key is public** in the page source — that's expected for Supabase's anon key, but
  it's why the SQL schema only grants it read/write on this one table, nothing else.
- **Auto-Fetch from Sleeper** still works the same way — it calls Sleeper's public API directly
  from the browser, no server needed.
- If you ever want real user accounts (so only the right person can edit their own team), that's
  a bigger change — Supabase supports auth too, but it's a separate step from this setup.
