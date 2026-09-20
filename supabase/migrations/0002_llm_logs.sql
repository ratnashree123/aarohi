-- F6 fine-tuning dataset: every LLM call, captured from day one.
-- decision/final_output/edits stay null for plain chat; the work-mode
-- approve/edit/reject flow (Phase 1c) fills them in.
create table llm_logs (
  id uuid primary key default gen_random_uuid(),
  provider text not null,            -- 'anthropic' | 'openai_compat'
  model text not null,
  conversation_id uuid,
  context text not null,             -- 'chat' | later: 'ticket', 'alarm', ...
  system_prompt text,
  input_messages jsonb not null,     -- full messages array sent to the model
  raw_output text,                   -- what the model said
  final_output text,                 -- what Mithun approved/sent (null = as-is)
  decision text check (decision in ('accepted','edited','rejected')),
  latency_ms int,
  created_at timestamptz not null default now()
);

alter table llm_logs enable row level security;
create policy "owner_all" on llm_logs for all to authenticated
  using (true) with check (true);
