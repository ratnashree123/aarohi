-- Aarohi — Phase 0 schema (full PRD core data model; Phase 0 uses the top four)
create extension if not exists vector;

-- persona, schedules, targets, device config — one jsonb row per key
create table profile_config (
  key text primary key,
  value jsonb not null,
  updated_at timestamptz not null default now()
);

create table conversations (
  id uuid primary key default gen_random_uuid(),
  device_role text not null default 'companion',
  started_at timestamptz not null default now()
);

create table messages (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references conversations(id) on delete cascade,
  role text not null check (role in ('user','assistant')),
  content text not null,
  device_role text,
  created_at timestamptz not null default now()
);
create index on messages (conversation_id, created_at);

create table memories (
  id uuid primary key default gen_random_uuid(),
  type text not null default 'fact',
  content text not null,
  -- ponytail: embedding stays null in Phase 0; keyword retrieval only.
  -- Fill via an embeddings model + pgvector search when keyword recall falls short.
  embedding vector(384),
  created_at timestamptz not null default now()
);

-- Phase 1 tables (schema now, features later)
create table tasks_bills (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  kind text not null default 'task' check (kind in ('task','bill')),
  due_date date,
  recurrence text,
  status text not null default 'open' check (status in ('open','done','skipped')),
  created_at timestamptz not null default now()
);

create table water_logs (
  id uuid primary key default gen_random_uuid(),
  amount_ml int not null,
  logged_at timestamptz not null default now()
);

create table workouts (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  split_day text,
  exercises jsonb not null default '[]'
);

create table workout_logs (
  id uuid primary key default gen_random_uuid(),
  exercise text not null,
  weight_kg numeric,
  reps int,
  logged_at timestamptz not null default now()
);

create table macros (
  id uuid primary key default gen_random_uuid(),
  number int,
  title text not null,
  body text not null
);

create table tickets (
  id uuid primary key default gen_random_uuid(),
  ocr_text text not null,
  decision text,
  final_reply text,
  outcome text,
  created_at timestamptz not null default now()
);

-- F6: every trigger fired and the response — the fine-tuning dataset
create table events_log (
  id uuid primary key default gen_random_uuid(),
  event_type text not null,
  payload jsonb not null default '{}',
  created_at timestamptz not null default now()
);

-- Single user: any authenticated session gets full access; anon gets nothing.
do $$
declare t text;
begin
  foreach t in array array['profile_config','conversations','messages','memories',
    'tasks_bills','water_logs','workouts','workout_logs','macros','tickets','events_log']
  loop
    execute format('alter table %I enable row level security', t);
    execute format('create policy "owner_all" on %I for all to authenticated using (true) with check (true)', t);
  end loop;
end $$;

-- Default persona (editable from the Persona Control Panel in the app)
insert into profile_config (key, value) values (
  'persona',
  jsonb_build_object(
    'name', 'Aarohi',
    'system_prompt',
    'You are Aarohi, Mithun''s personal AI companion. You are warm, encouraging, and a little persistent. You know his life: daily gym, QA/support job handling tickets, water targets, bills. Speak in short sentences. Pause often. Never rush. Be honest when he slacks — missed water, skipped tasks — but stay kind.',
    'model', 'claude-opus-4-8',
    'voice_enabled', true,
    'speech_rate', 0.85
  )
);
