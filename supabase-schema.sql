-- Backups Only League — multi-league schema (v2)
-- Run this once in your Supabase project's SQL Editor (Project -> SQL Editor -> New Query).
-- Safe to re-run: every statement is idempotent (create-if-not-exists / drop-then-create).
--
-- This supersedes the original single-league "one JSON blob per key" model with real
-- per-league tables and real per-user permissions, enforced by Postgres Row Level
-- Security (RLS) — not just hidden in the UI. It requires Supabase Auth (email magic
-- link) to be enabled in your project: Authentication -> Providers -> Email.
--
-- You also need Supabase Auth's redirect URL allow-list to include your site's URL:
-- Authentication -> URL Configuration -> Redirect URLs.

create extension if not exists pgcrypto;

-- ============================================================
-- Legacy table (kept only so a new commissioner can one-time-import
-- their old single-league data). The app no longer reads/writes this
-- once a league has been created — see the "Create League" import
-- option in the app.
-- ============================================================
create table if not exists league_kv (
  key text primary key,
  value text not null,
  updated_at timestamptz default now()
);
alter table league_kv enable row level security;

drop policy if exists "Allow anon read" on league_kv;
create policy "Allow anon read" on league_kv for select using (true);
drop policy if exists "Allow anon write" on league_kv;
create policy "Allow anon write" on league_kv for insert with check (true);
drop policy if exists "Allow anon update" on league_kv;
create policy "Allow anon update" on league_kv for update using (true);

-- ============================================================
-- Core tables
-- ============================================================

create table if not exists leagues (
  id text primary key,                      -- short invite code, e.g. 6 chars
  name text not null,
  commissioner_user_id uuid references auth.users(id),
  created_at timestamptz default now()
);

create table if not exists league_settings (
  league_id text primary key references leagues(id) on delete cascade,
  rules text default '',
  weights jsonb default '{}'::jsonb,
  num_qb int default 2,
  num_def int default 1,
  num_k int default 1,
  num_superflex int default 1,
  bench_size int default 3,
  draft_scheduled_at timestamptz,
  draft_type text default 'snake',
  pick_time_seconds int default 90,
  draft_order_method text default 'random',
  manual_order jsonb default '[]'::jsonb,
  autopick_enabled boolean default true
);

create table if not exists draft_runtime (
  league_id text primary key references leagues(id) on delete cascade,
  draft_started boolean default false,
  draft_order jsonb default '[]'::jsonb,    -- team ids in pick order
  draft_paused boolean default false,
  current_pick_deadline timestamptz,
  paused_remaining_ms bigint
);

create table if not exists teams (
  id uuid primary key default gen_random_uuid(),
  league_id text references leagues(id) on delete cascade,
  name text not null,
  owner_name text,
  owner_user_id uuid references auth.users(id),
  avatar_url text,
  created_at timestamptz default now()
);
alter table teams add column if not exists avatar_url text;

create table if not exists players (
  id uuid primary key default gen_random_uuid(),
  league_id text references leagues(id) on delete cascade,
  name text not null,
  pos text not null,
  nfl_team text,
  third_string boolean default false
);

create table if not exists picks (
  id uuid primary key default gen_random_uuid(),
  league_id text references leagues(id) on delete cascade,
  team_id uuid references teams(id),
  player_id uuid references players(id),
  pick_number int not null,
  auto boolean default false,
  created_at timestamptz default now(),
  unique (league_id, pick_number),
  unique (league_id, player_id)
);

create table if not exists queues (
  team_id uuid references teams(id) on delete cascade,
  player_id uuid references players(id) on delete cascade,
  league_id text references leagues(id) on delete cascade,
  rank int not null,
  primary key (team_id, player_id)
);

create table if not exists scores (
  league_id text references leagues(id) on delete cascade,
  week text not null,
  player_id uuid references players(id) on delete cascade,
  points numeric default 0,
  primary key (league_id, week, player_id)
);

create table if not exists lineups (
  league_id text references leagues(id) on delete cascade,
  week text not null,
  team_id uuid references teams(id) on delete cascade,
  slot_id text not null,
  player_id uuid references players(id),
  primary key (league_id, week, team_id, slot_id)
);

create table if not exists chat_messages (
  id uuid primary key default gen_random_uuid(),
  league_id text references leagues(id) on delete cascade,
  author text,
  text text not null,
  created_at timestamptz default now()
);

create table if not exists league_members (
  league_id text references leagues(id) on delete cascade,
  email text not null,
  suggested_team_name text,
  user_id uuid references auth.users(id),
  team_id uuid references teams(id),
  status text default 'pending',            -- 'pending' | 'joined'
  invited_at timestamptz default now(),
  primary key (league_id, email)
);

-- Columns added after the tables above may already exist on a project that ran an
-- earlier version of this file — add them defensively so re-running never errors.
alter table league_members add column if not exists suggested_team_name text;

-- ============================================================
-- Row Level Security
-- ============================================================

alter table leagues enable row level security;
alter table league_settings enable row level security;
alter table draft_runtime enable row level security;
alter table teams enable row level security;
alter table players enable row level security;
alter table picks enable row level security;
alter table queues enable row level security;
alter table scores enable row level security;
alter table lineups enable row level security;
alter table chat_messages enable row level security;
alter table league_members enable row level security;

-- leagues: public read (need to resolve a code to a name before login); only an
-- authenticated user can create themselves as commissioner; only the commissioner
-- can update their own league.
drop policy if exists "leagues select" on leagues;
create policy "leagues select" on leagues for select using (true);
drop policy if exists "leagues insert" on leagues;
create policy "leagues insert" on leagues for insert with check (auth.uid() = commissioner_user_id);
drop policy if exists "leagues update" on leagues;
create policy "leagues update" on leagues for update using (auth.uid() = commissioner_user_id);

-- league_settings: public read (rules/lineup config are viewable by anyone); only
-- that league's commissioner can write.
drop policy if exists "league_settings select" on league_settings;
create policy "league_settings select" on league_settings for select using (true);
drop policy if exists "league_settings insert" on league_settings;
create policy "league_settings insert" on league_settings for insert with check (
  exists (select 1 from leagues l where l.id = league_settings.league_id and l.commissioner_user_id = auth.uid())
);
drop policy if exists "league_settings update" on league_settings;
create policy "league_settings update" on league_settings for update using (
  exists (select 1 from leagues l where l.id = league_settings.league_id and l.commissioner_user_id = auth.uid())
);

-- draft_runtime: public read; commissioner creates the row at league setup; updates
-- are open (starting the draft / advancing picks stays a shared room action, same as
-- before) except pause/resume/reset, which a trigger below locks to the commissioner.
drop policy if exists "draft_runtime select" on draft_runtime;
create policy "draft_runtime select" on draft_runtime for select using (true);
drop policy if exists "draft_runtime insert" on draft_runtime;
create policy "draft_runtime insert" on draft_runtime for insert with check (
  exists (select 1 from leagues l where l.id = draft_runtime.league_id and l.commissioner_user_id = auth.uid())
);
drop policy if exists "draft_runtime update" on draft_runtime;
create policy "draft_runtime update" on draft_runtime for update using (true);

-- teams: public read; a friend can create their own team when they join, OR the
-- commissioner can add a placeholder team on behalf of someone who'd rather not make
-- an account (owner_user_id left null until/unless that person ever logs in and
-- claims it — not automated here, kept manual and simple); the team's owner or the
-- league's commissioner can update it; only the commissioner can delete a team.
drop policy if exists "teams select" on teams;
create policy "teams select" on teams for select using (true);
drop policy if exists "teams insert" on teams;
create policy "teams insert" on teams for insert with check (
  auth.uid() = owner_user_id
  or exists (select 1 from leagues l where l.id = teams.league_id and l.commissioner_user_id = auth.uid())
);
drop policy if exists "teams update" on teams;
create policy "teams update" on teams for update using (
  auth.uid() = owner_user_id
  or exists (select 1 from leagues l where l.id = teams.league_id and l.commissioner_user_id = auth.uid())
);
drop policy if exists "teams delete" on teams;
create policy "teams delete" on teams for delete using (
  exists (select 1 from leagues l where l.id = teams.league_id and l.commissioner_user_id = auth.uid())
);

-- players: public read; only the commissioner manages the pool (unchanged from before).
drop policy if exists "players select" on players;
create policy "players select" on players for select using (true);
drop policy if exists "players insert" on players;
create policy "players insert" on players for insert with check (
  exists (select 1 from leagues l where l.id = players.league_id and l.commissioner_user_id = auth.uid())
);
drop policy if exists "players update" on players;
create policy "players update" on players for update using (
  exists (select 1 from leagues l where l.id = players.league_id and l.commissioner_user_id = auth.uid())
);
drop policy if exists "players delete" on players;
create policy "players delete" on players for delete using (
  exists (select 1 from leagues l where l.id = players.league_id and l.commissioner_user_id = auth.uid())
);

-- picks: public read; making a pick stays open to anyone in the room, same as the
-- existing draft room (the spec's ownership rules only lock down team name + queue,
-- not who's allowed to click "Draft"). A trigger below still guards that a pick's
-- team/player actually belong to its own league. Only the commissioner can delete
-- (used by Reset Draft).
drop policy if exists "picks select" on picks;
create policy "picks select" on picks for select using (true);
drop policy if exists "picks insert" on picks;
create policy "picks insert" on picks for insert with check (true);
drop policy if exists "picks delete" on picks;
create policy "picks delete" on picks for delete using (
  exists (select 1 from leagues l where l.id = picks.league_id and l.commissioner_user_id = auth.uid())
);

-- queues: public read (so autopick and spectators can see them); only the owning
-- team's logged-in user can add/reorder/remove from their own queue.
drop policy if exists "queues select" on queues;
create policy "queues select" on queues for select using (true);
drop policy if exists "queues insert" on queues;
create policy "queues insert" on queues for insert with check (
  exists (select 1 from teams t where t.id = queues.team_id and t.owner_user_id = auth.uid())
);
drop policy if exists "queues update" on queues;
create policy "queues update" on queues for update using (
  exists (select 1 from teams t where t.id = queues.team_id and t.owner_user_id = auth.uid())
);
drop policy if exists "queues delete" on queues;
create policy "queues delete" on queues for delete using (
  exists (select 1 from teams t where t.id = queues.team_id and t.owner_user_id = auth.uid())
);

-- scores / lineups: unchanged from before — open to anyone to enter (no gating in
-- the original app either); this feature is scoped to auth/leagues, not scoring.
drop policy if exists "scores select" on scores;
create policy "scores select" on scores for select using (true);
drop policy if exists "scores insert" on scores;
create policy "scores insert" on scores for insert with check (true);
drop policy if exists "scores update" on scores;
create policy "scores update" on scores for update using (true);

drop policy if exists "lineups select" on lineups;
create policy "lineups select" on lineups for select using (true);
drop policy if exists "lineups insert" on lineups;
create policy "lineups insert" on lineups for insert with check (true);
drop policy if exists "lineups update" on lineups;
create policy "lineups update" on lineups for update using (true);

-- chat_messages: unchanged — open to anyone, no login required.
drop policy if exists "chat select" on chat_messages;
create policy "chat select" on chat_messages for select using (true);
drop policy if exists "chat insert" on chat_messages;
create policy "chat insert" on chat_messages for insert with check (true);

-- league_members: only the commissioner can see/manage the invite list (keeps
-- friends' email addresses private from each other); the invited person can update
-- their own row (by email match on their JWT) when they accept and join. Someone can
-- also self-insert their own row (by email match) — this app allows joining a league
-- straight from the shared link, not only via a formal invite, so self-service
-- team-creation still shows up in the commissioner's member list.
drop policy if exists "members select" on league_members;
create policy "members select" on league_members for select using (
  exists (select 1 from leagues l where l.id = league_members.league_id and l.commissioner_user_id = auth.uid())
  or (auth.jwt() ->> 'email') = league_members.email
);
drop policy if exists "members insert" on league_members;
create policy "members insert" on league_members for insert with check (
  exists (select 1 from leagues l where l.id = league_members.league_id and l.commissioner_user_id = auth.uid())
  or (auth.jwt() ->> 'email') = league_members.email
);
drop policy if exists "members update" on league_members;
create policy "members update" on league_members for update using (
  (auth.jwt() ->> 'email') = league_members.email
  or exists (select 1 from leagues l where l.id = league_members.league_id and l.commissioner_user_id = auth.uid())
);
drop policy if exists "members delete" on league_members;
create policy "members delete" on league_members for delete using (
  exists (select 1 from leagues l where l.id = league_members.league_id and l.commissioner_user_id = auth.uid())
);

-- ============================================================
-- Trigger guards (business rules RLS alone can't express)
-- ============================================================

-- Cap a league at 10 members (matches the 4-10 member requirement; the 4-member
-- minimum-to-start-draft check happens in the app, since it's a soft pre-draft warning
-- rather than a hard data constraint).
create or replace function enforce_league_member_cap() returns trigger as $$
begin
  if (select count(*) from league_members where league_id = new.league_id) >= 10 then
    raise exception 'This league already has the maximum of 10 members.';
  end if;
  return new;
end;
$$ language plpgsql;

drop trigger if exists trg_league_member_cap on league_members;
create trigger trg_league_member_cap
  before insert on league_members
  for each row execute function enforce_league_member_cap();

-- Same 10-member cap, but on the teams table directly — joining works straight from
-- the shared league link (self-service), not only through a commissioner invite, so
-- the cap has to hold there too, not just on the league_members invite list.
create or replace function enforce_team_cap() returns trigger as $$
begin
  if (select count(*) from teams where league_id = new.league_id) >= 10 then
    raise exception 'This league already has the maximum of 10 teams.';
  end if;
  return new;
end;
$$ language plpgsql;

drop trigger if exists trg_team_cap on teams;
create trigger trg_team_cap
  before insert on teams
  for each row execute function enforce_team_cap();

-- A pick's team and player must actually belong to the pick's own league (stops a
-- pick row from being inserted with mismatched foreign keys across leagues).
create or replace function enforce_pick_league_match() returns trigger as $$
begin
  if not exists (select 1 from teams where id = new.team_id and league_id = new.league_id) then
    raise exception 'That team does not belong to this league.';
  end if;
  if not exists (select 1 from players where id = new.player_id and league_id = new.league_id) then
    raise exception 'That player does not belong to this league.';
  end if;
  return new;
end;
$$ language plpgsql;

drop trigger if exists trg_pick_league_match on picks;
create trigger trg_pick_league_match
  before insert on picks
  for each row execute function enforce_pick_league_match();

-- Stamp queues.league_id from the team automatically, so RLS/selects don't need a join.
create or replace function set_queue_league_id() returns trigger as $$
begin
  select league_id into new.league_id from teams where id = new.team_id;
  return new;
end;
$$ language plpgsql;

drop trigger if exists trg_set_queue_league_id on queues;
create trigger trg_set_queue_league_id
  before insert on queues
  for each row execute function set_queue_league_id();

-- draft_runtime.update is open (see policy above) so the draft room keeps working
-- for everyone the way it always has, EXCEPT pausing/resuming or resetting an
-- in-progress draft, which only the commissioner may do.
create or replace function enforce_draft_runtime_guard() returns trigger as $$
declare
  is_commissioner boolean;
begin
  select (l.commissioner_user_id = auth.uid()) into is_commissioner
  from leagues l where l.id = new.league_id;

  if (new.draft_paused is distinct from old.draft_paused) and not coalesce(is_commissioner, false) then
    raise exception 'Only the commissioner can pause or resume the draft.';
  end if;
  if (old.draft_started = true and new.draft_started = false) and not coalesce(is_commissioner, false) then
    raise exception 'Only the commissioner can reset the draft.';
  end if;
  return new;
end;
$$ language plpgsql;

drop trigger if exists trg_draft_runtime_guard on draft_runtime;
create trigger trg_draft_runtime_guard
  before update on draft_runtime
  for each row execute function enforce_draft_runtime_guard();

-- ============================================================
-- Realtime: push updates to every connected screen instantly.
-- ============================================================
do $$
declare
  t text;
begin
  foreach t in array array[
    'leagues','league_settings','draft_runtime','teams','players',
    'picks','queues','scores','lineups','chat_messages','league_members'
  ]
  loop
    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t
    ) then
      execute format('alter publication supabase_realtime add table %I', t);
    end if;
  end loop;
end $$;

-- ============================================================
-- Storage: a public bucket for team profile pictures. Anyone can
-- view avatars; any signed-in user can upload one (the actual
-- claim of "this is now my team's picture" is protected by the
-- owner-only update policy on teams.avatar_url above).
-- ============================================================
insert into storage.buckets (id, name, public)
values ('avatars', 'avatars', true)
on conflict (id) do nothing;

drop policy if exists "Public read avatars" on storage.objects;
create policy "Public read avatars" on storage.objects
  for select using (bucket_id = 'avatars');

drop policy if exists "Authenticated upload avatars" on storage.objects;
create policy "Authenticated upload avatars" on storage.objects
  for insert with check (bucket_id = 'avatars' and auth.role() = 'authenticated');

drop policy if exists "Authenticated update avatars" on storage.objects;
create policy "Authenticated update avatars" on storage.objects
  for update using (bucket_id = 'avatars' and auth.role() = 'authenticated');
