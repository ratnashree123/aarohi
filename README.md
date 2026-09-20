# Aarohi — Personal AI Companion

Phase 0 build per `PRD-personal-ai-companion.md`. One Flutter app (two device
roles), Supabase brain, Claude via Edge Function. Design from
`stitch_aarohi_ai_companion/`.

```
app/        Flutter app (Android)
supabase/   DB schema + `chat` Edge Function
```

## One-time setup

1. **Create a Supabase project** at supabase.com (free tier is fine).

2. **Apply the schema** — SQL Editor → run:
   - `supabase/migrations/0001_init.sql` (core persona, messages, memories)
   - `supabase/migrations/0002_llm_logs.sql` (AI telemetry)
   - `supabase/migrations/0003_gym_seed.sql` (gym workouts)
   - `supabase/migrations/0004_calls_and_bookings.sql` (AI call screening & bookings hub)

3. **Create your single user** — Dashboard → Authentication → Add user
   (your email + a password). No signup flow exists in the app on purpose.

4. **Deploy the Edge Functions & Set Gemini API Secret** (needs the [Supabase CLI](https://supabase.com/docs/guides/cli)):
   ```sh
   cd C:\Aarohi
   npx supabase login
   npx supabase link --project-ref YOUR_PROJECT_REF

   # 24/7 Cloud AI via Google Gemini (zero laptop dependencies!):
   npx supabase secrets set GEMINI_API_KEY=your_gemini_api_key LLM_MODEL=gemini-2.5-flash

   # Deploy the Edge Functions:
   npx supabase functions deploy chat
   npx supabase functions deploy work
   npx supabase functions deploy call_agent
   ```

5. **Point the app at your project** — edit `app/lib/config.dart` with the
   Project URL and publishable/anon key (Dashboard → Settings → API).

6. **Run it**:
   ```sh
   cd C:\Aarohi\app
   flutter run          # phone connected via USB, developer mode on
   ```
   Install on both phones; pick **Companion** on the main phone and
   **Work Station** on the M32 at first launch.

## Features & Capabilities

- **24/7 Cloud AI Brain via Gemini**: Aarohi is always online with Google Gemini 2.5 Flash / 1.5 Flash. No local laptop, Ollama process, or Tailscale funnel needed.
- **AI Call Screener & Booking Hub (Main Phone)**:
  - **Incoming Call Screening**: Aarohi answers, asks why callers are calling, logs their reason, checks booking requests, and updates your calendar.
  - **Outbound Booking Confirmation**: Select any appointment (dentist, dinner, car service) and Aarohi initiates a confirmation call.
  - **Call History**: Complete log of all past screened calls with prominent "Reason for Call" tags and conversation summaries.
- **Chat & Persistent Memory**: Durable facts saved inline with `<remember>` tags, keyword recall, and unified cross-device memory.
- **Persona Control Panel**: Edit her system prompt, voice, and speech speed anytime.
- **Ticket Work Station (M32)**: Camera OCR screen watcher with Gemini-driven macro recommendations.

## LLM Provider Configuration

Google Gemini is the default cloud provider:
```sh
npx supabase secrets set GEMINI_API_KEY=your_gemini_api_key LLM_MODEL=gemini-2.5-flash
```

If you ever wish to route to an alternate OpenAI-compatible endpoint (e.g. self-hosted fine-tuned model):
```sh
npx supabase secrets set LLM_PROVIDER=own-model LLM_BASE_URL=https://.../v1 \
  LLM_MODEL=aarohi-qlora-v1 LLM_API_KEY=token-or-placeholder
```

## Deliberately skipped (add in Phase 1)

- Alarm + snooze escalation, water pings, bills (1a) — needs native exact-alarm
  plugin + pg_cron/FCM push.
- Gym voice logging, rest timer, media controls (1b) — Gym tab is a shell.
- Camera OCR, macro assist, BT HID typing (1c) — Work tab is a shell.
- pgvector semantic memory — `memories.embedding` column exists, retrieval is
  keyword-only for now.
- Model: `claude-opus-4-8` (change in `profile_config.persona.model` — e.g.
  `claude-sonnet-5` or `claude-haiku-4-5` if chat volume makes cost matter).
