// Aarohi Call Agent — Inbound Call Screening & Outbound Booking Confirmation
// Powered 24/7 by Google Gemini Cloud API.
// Handles live phone call dialogues, asks why callers are calling,
// verifies/confirms bookings against the database, and stores structured call logs.
import { createClient } from "npm:@supabase/supabase-js@2";

const db = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

type CallTurn = { role: "assistant" | "caller"; content: string };

interface CallAgentPayload {
  action: "start" | "dialogue" | "outbound_start" | "end";
  direction?: "inbound" | "outbound";
  caller_name?: string;
  caller_phone?: string;
  booking_id?: string;
  caller_message?: string;
  transcript?: CallTurn[];
}

interface GeminiCallDecision {
  reply: string;
  emotion: number;
  call_reason: string;
  detected_caller_name?: string;
  booking_action: "none" | "confirm" | "reschedule" | "cancel";
  matched_booking_id?: string | null;
  summary: string;
  status: "completed" | "urgent" | "callback_needed";
  call_completed: boolean;
}

async function callGemini(
  apiKey: string,
  model: string,
  system: string,
  prompt: string,
): Promise<string> {
  const cleanModel = model.startsWith("gemini") ? model : "gemini-3.5-flash-lite";
  const url = `https://generativelanguage.googleapis.com/v1beta/models/${cleanModel}:generateContent?key=${apiKey}`;

  const res = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      system_instruction: {
        parts: [{ text: system }],
      },
      contents: [{ role: "user", parts: [{ text: prompt }] }],
      generationConfig: {
        maxOutputTokens: 1024,
        temperature: 0.3,
        responseMimeType: "application/json",
      },
    }),
    signal: AbortSignal.timeout(30_000),
  });

  if (!res.ok) {
    const err = await res.text();
    throw new Error(`Gemini Call Agent ${res.status}: ${err}`);
  }
  const data = await res.json();
  const parts = data.candidates?.[0]?.content?.parts ?? [];
  const textPart = parts.find((p: any) => p.text && !p.thought) ?? parts[0];
  return textPart?.text ?? "{}";
}

Deno.serve(async (req) => {
  const payload: CallAgentPayload = await req.json();
  const {
    action = "dialogue",
    direction = "inbound",
    caller_name = "",
    caller_phone = "",
    booking_id,
    caller_message = "",
    transcript = [],
  } = payload;

  const geminiKey = Deno.env.get("GEMINI_API_KEY") || Deno.env.get("LLM_API_KEY");
  const model = Deno.env.get("LLM_MODEL") ?? "gemini-3.5-flash-lite";

  // Quick initial greetings for fast latency
  if (action === "start") {
    const greeting =
      "Hi, I'm Aarohi, Mithun's AI assistant. He's currently occupied. May I ask the reason for your call?";
    return Response.json({
      reply: greeting,
      emotion: 0.6,
      call_reason: "Awaiting caller reason...",
      call_completed: false,
    });
  }

  if (action === "outbound_start") {
    let bookingDetail = "his upcoming appointment";
    if (booking_id) {
      const { data: b } = await db.from("bookings").select("title,booking_time,contact_name")
        .eq("id", booking_id).maybeSingle();
      if (b) {
        const timeStr = new Date(b.booking_time).toLocaleString();
        bookingDetail = `${b.title} scheduled for ${timeStr}`;
      }
    }
    const greeting =
      `Hello! I'm Aarohi, calling on behalf of Mithun to confirm ${bookingDetail}. Could you please verify if the booking is confirmed?`;
    return Response.json({
      reply: greeting,
      emotion: 0.6,
      call_reason: `Outbound booking confirmation: ${bookingDetail}`,
      call_completed: false,
    });
  }

  // Fetch upcoming bookings so Gemini can cross-reference
  const { data: upcomingBookings } = await db
    .from("bookings")
    .select("id,title,contact_name,phone_number,booking_time,status")
    .order("booking_time", { ascending: true })
    .limit(10);

  const bookingsContext = (upcomingBookings ?? [])
    .map(
      (b) =>
        `- ID: ${b.id} | Title: "${b.title}" | Contact: "${b.contact_name}" | Time: ${b.booking_time} | Current Status: ${b.status}`,
    )
    .join("\n");

  const formattedTranscript = transcript
    .map((t) => `${t.role.toUpperCase()}: ${t.content}`)
    .join("\n");

  const system = `You are Aarohi, Mithun's warm, articulate, and proactive personal AI phone assistant.
You are currently speaking directly on the phone with a caller.

GOALS:
1. Identify the clear, specific REASON WHY THEY CALLED (e.g. confirming a booking, asking for directions, courier delivery, personal question, rescheduling).
2. If they are calling regarding an existing booking, cross-reference against Mithun's upcoming bookings:
${bookingsContext || "(no bookings scheduled currently)"}
- If they confirm the booking, acknowledge warmly and set booking_action to "confirm" and match the ID.
- If they request a reschedule or cancellation, acknowledge and set booking_action accordingly.
3. Keep spoken replies short (1-2 sentences). Speak in natural, spoken conversational English. Never use Markdown or bracketed tags.
4. Output strictly valid JSON matching this schema:
{
  "reply": "spoken text to the caller",
  "emotion": 0.6, // float 0.5 (formal) to 0.75 (warm/sweet)
  "call_reason": "Specific reason why the person called",
  "detected_caller_name": "Name of person or company if mentioned, else empty string",
  "booking_action": "none" | "confirm" | "reschedule" | "cancel",
  "matched_booking_id": "UUID string if matches a booking, or null",
  "summary": "1-2 sentence recap of what happened during the call",
  "status": "completed" | "urgent" | "callback_needed",
  "call_completed": boolean // true if caller said goodbye, thanks, or conversation is wrapped
}`;

  const prompt = `Current Call Context:
Direction: ${direction}
Known Caller Name: ${caller_name || "Unknown"}
Caller Phone: ${caller_phone || "Not specified"}
Selected Booking ID: ${booking_id || "None"}

Conversation Transcript so far:
${formattedTranscript || "(start of call)"}

Caller just said: "${caller_message}"

Generate your spoken reply and structured analysis in JSON:`;

  if (!geminiKey) {
    return Response.json({
      reply: "I am having trouble accessing my AI brain right now. Please leave a message and Mithun will get back to you.",
      emotion: 0.5,
      call_reason: "AI key not configured",
      call_completed: true,
      summary: "Call could not be completed: GEMINI_API_KEY missing.",
      status: "callback_needed",
    });
  }

  let decision: GeminiCallDecision;
  try {
    const raw = await callGemini(geminiKey, model, system, prompt);
    decision = JSON.parse(raw);
  } catch (e) {
    console.error("Call agent error:", e);
    decision = {
      reply: "Thank you for the information. I have noted that down for Mithun and he will follow up shortly. Have a great day!",
      emotion: 0.6,
      call_reason: caller_message ? `Caller said: ${caller_message.slice(0, 100)}` : "Inbound inquiry",
      booking_action: "none",
      summary: `Caller contacted Mithun. Last message: ${caller_message}`,
      status: "completed",
      call_completed: true,
    };
  }

  // Handle booking status updates if identified
  const matchedId = decision.matched_booking_id || booking_id;
  if (matchedId && decision.booking_action !== "none") {
    try {
      await db.from("bookings").update({
        status: decision.booking_action === "confirm" ? "confirmed" :
          decision.booking_action === "reschedule" ? "rescheduled" :
          decision.booking_action === "cancel" ? "cancelled" : "pending",
      }).eq("id", matchedId);
    } catch (err) {
      console.error("Failed to update booking status:", err);
    }
  }

  // If the call has finished or action is 'end', record in call_logs
  const fullTranscript = [
    ...transcript,
    { role: "caller", content: caller_message },
    { role: "assistant", content: decision.reply },
  ].filter((t) => t.content && t.content.trim().length > 0);

  if (action === "end" || decision.call_completed) {
    try {
      await db.from("call_logs").insert({
        caller_name: decision.detected_caller_name || caller_name || "Unknown Caller",
        caller_phone: caller_phone || null,
        direction,
        call_reason: decision.call_reason || "General inquiry",
        booking_id: matchedId || null,
        summary: decision.summary,
        transcript: fullTranscript,
        status: decision.status || "completed",
      });
    } catch (logErr) {
      console.error("Failed to insert call_logs:", logErr);
    }
  }

  return Response.json({
    reply: decision.reply,
    emotion: decision.emotion ?? 0.6,
    call_reason: decision.call_reason,
    detected_caller_name: decision.detected_caller_name,
    booking_action: decision.booking_action,
    matched_booking_id: matchedId,
    summary: decision.summary,
    status: decision.status,
    call_completed: decision.call_completed,
  });
});
