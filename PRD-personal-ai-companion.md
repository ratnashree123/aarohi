# PRD — Personal AI Companion ("Mini Jarvis")

| | |
|---|---|
| **Owner** | Mithun |
| **Status** | Draft v1.1 — voice locked (Kokoro-82M) + Persona Control Panel added |
| **Date** | 15 July 2026 |
| **Type** | Personal tool (single user) |
| **Visual design** | Owned by Mithun (not covered in this PRD) |

---

## 1. Vision

A proactive AI companion with a persistent personality and memory that lives across two Android phones and one backend. She wakes Mithun up, coaches his gym sessions, watches his work screen and helps him handle support tickets faster, reminds him about bills and water, and talks with him about his day — remembering everything, every day.

Unlike existing assistants (ChatGPT, Gemini, Reclaim, etc.), which are either reactive (you open them and prompt them) or single-purpose (only calendar, only meds, only email), this system is **proactive and cross-domain**: one brain that knows the gym log, the work queue, and the life admin at the same time — and speaks first.

## 2. Goals

1. Wake up on time daily without relying on willpower.
2. Remove workout decision fatigue — the day's workout is already chosen when he arrives at the gym.
3. Hit daily water targets via timed nudges.
4. Cut ticket-handling time at work: faster macro selection and drafting, with reading/analysis assistance.
5. Never miss a bill or small recurring task.
6. Log every interaction from day one, so real usage becomes the training dataset for a personally fine-tuned model (Phase 2 — "my own model").

## 3. Non-Goals

- Not a product for other users. No auth flows beyond a single account, no onboarding, no billing.
- No fully automatic replies to customers. Every typed response requires explicit approval.
- No medical advice. Fitness suggestions are workout planning, not health treatment.
- No training a model from scratch. "Own model" = fine-tuned open-weight base (LoRA/QLoRA).
- Visual/UI design — handled separately by Mithun.

## 4. The User & Context

Single user: Mithun. QA/support role — incoming tickets require deciding whether an existing macro (canned response) fits or a new reply must be drafted. Self-described as slow at reading/analyzing ticket situations and not effective at managing everything at once. Goes to the gym daily but doesn't wake early easily, forgets water, and wastes time choosing workouts. Small life admin (bills etc.) slips through.

Constraints that shaped the design:

- Work laptop must stay untouched — nothing installed on it, no scripts, no API integration. The assistant interacts with it only through a camera (reading the screen) and Bluetooth (typing as an external keyboard).
- Company/customer data should stay on-device wherever possible (OCR runs locally).

## 5. System Overview — One "Her", Two Bodies, One Brain

```
┌─────────────────────────┐        ┌─────────────────────────┐
│  WORK BODY              │        │  LIFE BODY              │
│  Samsung Galaxy M32     │        │  Main phone             │
│  (desk holder, plugged  │        │                         │
│  in, work only)         │        │  • Wake-up alarm        │
│                         │        │  • Gym mode (voice)     │
│  • Camera → watches     │        │  • Water reminders      │
│    laptop screen        │        │  • Bills & tasks        │
│    continuously         │        │  • Daily conversations  │
│  • On-device OCR        │        │                         │
│  • Bluetooth HID →      │        │                         │
│    types approved text  │        │                         │
└───────────┬─────────────┘        └───────────┬─────────────┘
            │                                  │
            └──────────────┬───────────────────┘
                           ▼
              ┌─────────────────────────┐
              │  THE BRAIN — Supabase   │
              │  • All memory & logs    │
              │  • pg_cron triggers     │
              │  • Edge Functions       │
              │  • LLM calls (v1: API;  │
              │    Phase 2: own model)  │
              └─────────────────────────┘
```

One Flutter codebase. On first launch the device is assigned a **role** — `work_station` or `companion` — and the app enables the matching feature set. Both devices share the same Supabase project, so memory is unified: at the gym she knows what happened at work.

## 6. Persona ("Her")

- Female persona with persistent memory of Mithun's life, preferences, history, and ongoing goals.
- Implemented as: system prompt (personality, tone, name) + memory retrieval from Supabase injected into every LLM call.
- Tone: warm, encouraging, a little persistent (especially at wake-up), honest about slacking (missed water, skipped tasks).
- Voice: **Kokoro-82M** (open-source, Apache 2.0), voice **`af_bella`** (chosen by Mithun after testing), running **on-device via sherpa-onnx** — offline, free, no per-use cost. Delivery: slow and unrushed — speech speed ~0.85–0.9, short sentences with natural pauses (enforced via her system prompt: "speak in short sentences, pause often, never rush"). Android built-in TTS is used only as a Phase 0 placeholder and automatic fallback.
- **Persona Control Panel (required feature):** a settings screen where Mithun can edit her behavior at any time, no code changes:
  - **Response style** — free-text personality instructions (her system prompt is user-editable) plus quick sliders/toggles: formal ↔ casual, short ↔ chatty, gentle ↔ blunt.
  - **Reaction style** — how she reacts per situation: snoozed alarm, missed water, skipped task, good lift, bad day at work. Each reaction type has an editable intensity (calm nudge ↔ persistent push) and editable sample phrasing.
  - Voice picker (Kokoro voice + speech speed/pitch).
  - Changes save to `profile_config` in Supabase and apply instantly on both devices.
- Name, voice, and all style settings: **decided by Mithun during setup**, editable anytime via the control panel.
- Guardrail: persona is a companion layer, not a decision-maker — anything that touches work output (typing to customers) always goes through explicit approval.

## 7. Features

### F1 — Companion Core (both devices)

- Chat interface (text + voice input, voice output).
- Long-term memory: facts, preferences, and events stored in Supabase; relevant memories retrieved (keyword + pgvector semantic search) and injected into context per conversation.
- Proactive engine: pg_cron jobs + Edge Functions fire scheduled and conditional messages (wake-up, water, bills, evening check-in) via FCM push → the app speaks/notifies.
- Every conversation turn is logged (see F6).

### F2 — Wake-Up & Morning Routine (main phone)

- Talking alarm at the configured time: speaks the day's plan (workout of the day, first tasks).
- Snooze escalation: each snooze makes her more persistent (louder, chattier, calls out consequences: "Gym window closes in 25 minutes").
- Alarm must fire reliably: implemented as a native Android alarm (exact alarm permission) — not just a push notification.
- Morning summary after wake-up confirmed: today's workout, tasks due, bills approaching.

### F3 — Gym Mode (main phone, voice-first)

- **Workout of the day**: pre-selected from a configurable split (e.g., push/pull/legs) + last session's history. Presented at wake-up and on gym-mode start. No searching.
- **Voice set logging**: "bench 60, 8 reps" → parsed and logged. She responds with context: "2 more than Monday. One more set."
- **Water nudges**: during the gym window and across the day, timed pings against a daily target; intake logged by voice or tap.
- **Music control**: "change the song / skip / play something heavy" → controls the active media session on the phone (works with any music app via Android media controls). Specific app integration (e.g., Spotify API for mood-based picks) is a later enhancement.
- **Coaching conversation**: between sets or post-workout, casual talk about the day and how to do better tomorrow — grounded in real data (tickets handled, water intake, missed tasks, lift progression).
- Designed for Bluetooth earbuds; fully usable without looking at the screen.

### F4 — Work Mode (Galaxy M32, desk holder)

The centerpiece. Zero footprint on the work laptop.

**Her eyes — continuous screen watching:**
- Camera points at the laptop screen; device stays plugged in.
- Frame-differencing loop: capture at a low interval, compare to previous frame, run OCR **only when the screen changes meaningfully** (new ticket, new customer message). Keeps the Helio G80 cool and responsive.
- OCR is **on-device** (Google ML Kit, offline) — raw customer text is extracted locally.
- Practical setup requirements (one-time): fixed holder angle, increased ticket font size, glare-free positioning. A built-in "calibration view" shows what she can read.

**Her judgment — macro decision assist:**
- Extracted ticket text → LLM analysis → one of:
  - "**Macro #12 fits** — here's why" (macros are pre-loaded into her memory by Mithun), or
  - "**No macro fits** — here's a draft reply," plus a short plain-language summary of the situation (directly targets the slow-reading pain point).
- Mithun reviews on the M32 screen: **Approve / Edit / Reject**.

**Her hands — Bluetooth typing:**
- M32 is paired to the laptop as a **Bluetooth HID keyboard** (native Android API, Android 9+; M32 qualifies). To the laptop it is indistinguishable from a physical keyboard — nothing installed.
- On Approve: she types the text into whatever field has focus. A short countdown ("typing in 3…2…1") lets Mithun place the cursor.
- Hard rule: **no keystroke is ever sent without an explicit approval tap.**

**Compliance note:** Mithun verifies his employer's policy on AI assistance with customer data before enabling cloud LLM calls in work mode. Mitigation available: v1 can run work-mode analysis with customer text redacted (names/emails stripped on-device before the LLM call), and Phase 2 moves inference fully on-device/own-model.

### F5 — Life Admin (main phone)

- Bills and recurring tasks with due dates; reminders escalate as the date approaches ("electricity bill due in 3 days… tomorrow… today, do it now, it takes 2 minutes").
- Quick capture by voice or text: "remind me to renew hosting on the 25th."
- Evening check-in message: water total vs target, tasks closed/open, tomorrow's workout, upcoming bills.

### F6 — Data Collection Layer (invisible, day one)

The bridge to "my own model." Everything is logged in structured form:

| Signal | Used for (Phase 2) |
|---|---|
| Conversation turns (both devices) | Persona fine-tuning — how she should talk to him |
| Ticket text → macro chosen (approve/reject/edit + final text) | The macro-judgment model — his decision style |
| Draft replies + his edits | Drafting style fine-tuning |
| Workout selections & set logs | Better workout suggestions |
| Reminder responses (acted on / snoozed / ignored) | Smarter nudge timing |

Target: after ~6 months of daily use, export as instruction-tuning pairs (input → his approved output) for LoRA fine-tuning.

## 8. Architecture & Stack

| Layer | Choice | Notes |
|---|---|---|
| App | **Flutter** (one codebase, device-role config) | Chat UI via an existing package (e.g., Flyer Chat) to skip building messaging UI |
| Backend | **Supabase** | Postgres + pgvector (semantic memory), Edge Functions (LLM orchestration), pg_cron (proactive triggers), Realtime (cross-device sync), FCM push |
| OCR | Google **ML Kit** text recognition | On-device, offline, free |
| Typing | Android **Bluetooth HID Device API** | M32 pairs to laptop as a keyboard |
| Voice out (her voice) | **Kokoro-82M** via sherpa-onnx | On-device, offline, Apache 2.0; female voice; Android TTS as Phase 0 placeholder/fallback |
| Voice in | Android speech recognition | Upgrade path: Whisper (STT) |
| LLM (v1) | Cloud API via Supabase Edge Function | Key never lives in the app |
| LLM (Phase 2) | **Own fine-tuned open-weight model** (LoRA/QLoRA on Llama/Qwen class base) | Trained on F6 data via free-tier GPU (Colab/Kaggle); served from home hardware, later quantized on-device |
| Automation (optional, Phase 3) | Raspberry Pi + n8n | Always-on jobs independent of Supabase |

**Core data model (Supabase):** `profile_config` (persona, schedules, targets, device roles) · `memories` (text + embedding, type, timestamps) · `conversations` / `messages` · `tasks_bills` (due dates, recurrence, status) · `water_logs` · `workouts` (split templates) / `workout_logs` (exercise, weight, reps) · `macros` (his company's canned responses) · `tickets` (OCR text — redacted, decision, final reply, outcome) · `events_log` (every trigger fired and his response).

**Starters to save time:**
- Flutter + Supabase skeleton: `SandroMaglione/flutter-supabase-template` (auth, env, DB wiring done)
- Chat UI: Flyer Chat (Supabase-backed Flutter chat package)
- Reference for the AI/memory backend patterns: `fletchertyler914/supabase-ai-starter-kit` (pgvector RAG, n8n, model connectors — mine it for patterns even if not used wholesale)

## 9. Roadmap

**Phase 0 — Foundation (week 1–2)**
Supabase project + schema · Flutter app from starter template · device-role config · chat with LLM via Edge Function · basic persona prompt + memory write/read. *Exit: he can talk to her on both phones and she remembers across devices.*

**Phase 1 — The Three Pillars (week 3–8)**
- 1a Life: talking alarm + snooze escalation, water pings, bills/tasks, evening check-in.
- 1b Gym: workout-of-the-day, voice set logging, media controls, coaching talk.
- 1c Work: camera calibration view → on-demand "read it" OCR → macro suggest/draft → approve → BT HID typing. Then upgrade on-demand to **continuous** watching (frame-diff loop).
- 1d Voice & persona: swap placeholder TTS for **Kokoro-82M via sherpa-onnx**; build the **Persona Control Panel** (response style, reaction style, voice picker).

*Order within Phase 1 is flexible; work mode (1c) is the highest-effort, highest-value slice.*

**Phase 2 — Own Model (month 4–8, once data exists)**
Export F6 logs → build instruction dataset → QLoRA fine-tune a small open-weight base → evaluate against API baseline on his own historical tickets → serve from home hardware; quantize a small variant for on-device where it fits. *Exit: her judgment and voice are literally trained on him, and work mode can run without cloud calls.*

**Phase 3 — Ambient upgrades (later)**
Whisper STT · Spotify-level music intelligence · Pi/n8n always-on automations · continuous listening at gym · smarter proactive timing learned from events_log.

## 10. Risks & Mitigations

| Risk | Level | Mitigation |
|---|---|---|
| Camera OCR misreads tickets | High | Calibration view, larger fonts, fixed holder, confidence threshold — she says "I can't read this clearly" instead of guessing; approval step catches errors |
| Employer policy on AI + customer data | High | Verify policy first; on-device redaction before any cloud call; Phase 2 removes cloud entirely |
| Wrong text typed into wrong field | Medium | Mandatory approval tap + typing countdown + "abort" tap that kills the keystroke stream instantly |
| M32 heat/battery from continuous camera | Medium | Plugged in always; frame-diff so OCR runs only on change; thermal check that drops capture rate |
| Android exact-alarm & background restrictions (Samsung is aggressive) | Medium | Exact alarm permission, battery-optimization exemption, foreground service for work mode |
| Fine-tuning underdelivers vs API | Medium | Phase 2 is additive — API path stays as fallback; evaluate before switching |
| Over-reliance / single point of failure | Low | All data is his, exportable; core reminders also fire as plain notifications if the LLM layer is down |
| Scope creep kills the build | High | Ship Phase 1a first (smallest, daily value on day one), then 1b, then 1c |

## 11. Open Questions

1. M32 RAM variant (4/6 GB) — only matters if on-device inference ever targets the work body.
2. Music app in use — media controls work regardless; deeper integration is app-specific.
3. Persona: her **name** — still to be decided by Mithun. (Voice resolved: Kokoro `af_bella`.)
4. Employer's written policy on AI tools with customer data — determines whether v1 work mode ships with redaction on or cloud calls off.
5. Ticket tool's macro list — needs a one-time import of all existing macros into the `macros` table.

## 12. Success Metrics (personal, measurable from events_log)

- Out of bed within 10 min of alarm ≥ 6 days/week.
- Water target hit ≥ 5 days/week.
- Average ticket handling time down ≥ 30% vs pre-app baseline (self-timed for one week before launch).
- Zero missed bill due dates.
- Gym sessions logged 7/7 (he already goes daily — the metric is that *logging* is effortless enough to actually happen).
- ≥ 5,000 high-quality logged interactions by month 6 (the Phase 2 dataset).
