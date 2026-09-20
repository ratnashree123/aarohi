-- Aarohi — Phase 1e: AI Call Screening, Call Logs & Bookings Hub
-- Enables Aarohi on the main phone to screen incoming calls, ask why someone is calling,
-- confirm bookings, and manage outbound confirmation calls.

create table if not exists bookings (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  contact_name text not null,
  phone_number text,
  booking_time timestamptz not null,
  status text not null default 'pending' check (status in ('pending', 'confirmed', 'cancelled', 'rescheduled')),
  notes text,
  created_at timestamptz not null default now()
);

create table if not exists call_logs (
  id uuid primary key default gen_random_uuid(),
  caller_name text,
  caller_phone text,
  direction text not null default 'inbound' check (direction in ('inbound', 'outbound')),
  call_reason text not null,
  booking_id uuid references bookings(id) on delete set null,
  summary text,
  transcript jsonb not null default '[]',
  status text not null default 'completed' check (status in ('completed', 'urgent', 'callback_needed')),
  created_at timestamptz not null default now()
);

create index if not exists idx_bookings_time on bookings (booking_time);
create index if not exists idx_call_logs_created on call_logs (created_at desc);

-- Enable RLS and authenticated access
alter table bookings enable row level security;
alter table call_logs enable row level security;

create policy "owner_all_bookings" on bookings for all to authenticated using (true) with check (true);
create policy "owner_all_call_logs" on call_logs for all to authenticated using (true) with check (true);

-- Seed realistic sample bookings
insert into bookings (title, contact_name, phone_number, booking_time, status, notes)
values
  ('Dental Cleaning', 'Dr. Alok Verma (Apex Dental)', '+91 98765 43210', now() + interval '1 day 4 hours', 'pending', 'Routine cleaning and checkup'),
  ('Car Maintenance Service', 'AutoCare Express', '+91 91234 56789', now() + interval '3 days 2 hours', 'confirmed', 'General service & oil check'),
  ('Physiotherapy Session', 'Dr. Neha Rao', '+91 99887 76655', now() + interval '5 days', 'pending', 'Posture & lower back consult');

-- Seed realistic sample screened call logs
insert into call_logs (caller_name, caller_phone, direction, call_reason, summary, transcript, status)
values
  (
    'Dr. Alok Verma (Apex Dental)',
    '+91 98765 43210',
    'inbound',
    'Calling to confirm tomorrow dental cleaning appointment at 3:00 PM',
    'Apex Dental called to check if Mithun is available for tomorrow 3 PM dental cleaning slot.',
    '[{"role": "assistant", "content": "Hi, I am Aarohi, Mithun AI assistant. He is currently occupied. May I ask the reason for your call?"}, {"role": "caller", "content": "Hello, this is Apex Dental clinic. We wanted to confirm Mithun appointment for dental cleaning tomorrow at 3 PM."}, {"role": "assistant", "content": "Thank you for calling. I have logged that and noted your confirmation request for Mithun."}]'::jsonb,
    'completed'
  ),
  (
    'BlueDart Courier Delivery',
    '+91 98111 22334',
    'inbound',
    'Delivery driver inquiring if security gate pass is required for parcel delivery',
    'Courier driver asking about apartment gate code to drop off package at door.',
    '[{"role": "assistant", "content": "Hi, I am Aarohi, Mithun AI assistant. How can I help you?"}, {"role": "caller", "content": "Hi, I am at the gate with Mithun parcel from BlueDart. Can someone approve gate entry?"}, {"role": "assistant", "content": "Understood, I am notifying Mithun right away so he can authorize security."}]'::jsonb,
    'urgent'
  );
