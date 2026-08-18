-- Backup Bowl storage schema
-- Run this once in your Supabase project's SQL Editor (Project -> SQL Editor -> New Query)

create table if not exists league_kv (
  key text primary key,
  value text not null,
  updated_at timestamptz default now()
);

-- This app is a trust-based friend league with no per-user login, so we allow
-- the public "anon" key to read and write this table directly (same honor-system
-- model as the in-app commissioner PIN). Do not put anything sensitive in here.
alter table league_kv enable row level security;

create policy "Allow anon read" on league_kv
  for select using (true);

create policy "Allow anon write" on league_kv
  for insert with check (true);

create policy "Allow anon update" on league_kv
  for update using (true);
