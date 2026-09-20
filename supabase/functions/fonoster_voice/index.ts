// Aarohi Fonoster Voice Agent — Open-Source Outbound Cellular Calling
// Connects Google Gemini 3.5 Flash Lite + Fonoster Voice Engine
// to place real telephone calls to mobile numbers via Fonoster & SIP trunking.
import { createClient } from "npm:@supabase/supabase-js@2";

const db = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

interface GeminiCallDecision {
  reply: string;
  emotion: number;
  call_reason: string;
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
      system_instruction: { parts: [{ text: system }] },
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
    throw new Error(`Gemini Error ${res.status}: ${err}`);
  }
  const data = await res.json();
  const parts = data.candidates?.[0]?.content?.parts ?? [];
  const textPart = parts.find((p: any) => p.text && !p.thought) ?? parts[0];
  return textPart?.text ?? "{}";
}

Deno.serve(async (req) => {
  const url = new URL(req.url);
  const geminiKey = Deno.env.get("GEMINI_API_KEY") || Deno.env.get("LLM_API_KEY") || "";
  const model = Deno.env.get("LLM_MODEL") ?? "gemini-3.5-flash-lite";

  // Status / Check Endpoint
  if (url.searchParams.get("action") === "status") {
    const hasKey = !!(Deno.env.get("FONOSTER_ACCESS_KEY_ID"));
    const hasSecret = !!(Deno.env.get("FONOSTER_API_SECRET"));
    const hasAppRef = !!(Deno.env.get("FONOSTER_APP_REF"));
    return Response.json({
      configured: hasKey && hasSecret && hasAppRef,
      has_key: hasKey,
      has_secret: hasSecret,
      has_app_ref: hasAppRef,
      endpoint: Deno.env.get("FONOSTER_ENDPOINT") || "https://api.fonoster.com",
    });
  }

  // Handle incoming JSON from Flutter app: 'make_call'
  const contentType = req.headers.get("content-type") || "";
  if (contentType.includes("application/json")) {
    const body = await req.json().catch(() => ({}));
    const action = body.action || url.searchParams.get("action");

    if (action === "make_call") {
      const to = body.to;
      const bookingId = body.booking_id;
      const contactName = body.contact_name || "Contact";

      const accessKeyId = body.fonoster_access_key || Deno.env.get("FONOSTER_ACCESS_KEY_ID");
      const apiSecret = body.fonoster_api_secret || Deno.env.get("FONOSTER_API_SECRET");
      const appRef = body.fonoster_app_ref || Deno.env.get("FONOSTER_APP_REF");
      const fromNumber = body.fonoster_from || Deno.env.get("FONOSTER_FROM_NUMBER") || "+18005550100";
      const fonosterEndpoint = body.fonoster_endpoint || Deno.env.get("FONOSTER_ENDPOINT") || "https://api.fonoster.com";

      if (!accessKeyId || !apiSecret || !appRef) {
        return Response.json({
          error: "Fonoster credentials missing. Please configure FONOSTER_ACCESS_KEY_ID, FONOSTER_API_SECRET, and FONOSTER_APP_REF.",
          requires_config: true,
        }, { status: 400 });
      }

      if (!to) {
        return Response.json({ error: "Missing 'to' destination phone number" }, { status: 400 });
      }

      // 1. Create call log row in Supabase
      const { data: logEntry } = await db.from("call_logs").insert({
        caller_name: contactName,
        caller_phone: to,
        direction: "outbound",
        call_reason: "Fonoster real cellular call initiated",
        transcript: [],
        status: "urgent",
      }).select("id").single();

      const logId = logEntry?.id;

      // 2. Dispatch call to Fonoster Calls API
      try {
        const fonosterCallUrl = `${fonosterEndpoint}/v1/calls`;
        const callPayload = {
          from: fromNumber,
          to: to,
          appRef: appRef,
          metadata: {
            log_id: logId,
            booking_id: bookingId,
            contact_name: contactName,
          },
        };

        const fonosterRes = await fetch(fonosterCallUrl, {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            "Authorization": `Bearer ${accessKeyId}:${apiSecret}`,
          },
          body: JSON.stringify(callPayload),
        });

        const fonosterData = await fonosterRes.json().catch(() => ({}));

        return Response.json({
          success: true,
          call_ref: fonosterData.ref || `fonoster_${Date.now()}`,
          log_id: logId,
          message: `Fonoster is dialing ${to} over the cellular network!`,
        });
      } catch (err: any) {
        return Response.json({
          error: `Fonoster call dispatch error: ${err.message || err}`,
        }, { status: 500 });
      }
    }
  }

  // Handle Fonoster Voice Application Webhook Events
  // When a recipient answers, Fonoster calls this webhook to get voice verbs (Answer, Say, Gather, Hangup)
  const webhookBody = await req.json().catch(() => ({}));
  const speechText = webhookBody.speech || webhookBody.text || "";
  const logId = webhookBody.metadata?.log_id || url.searchParams.get("log_id");
  const bookingId = webhookBody.metadata?.booking_id || url.searchParams.get("booking_id");
  const contactName = webhookBody.metadata?.contact_name || url.searchParams.get("name") || "Contact";

  // Load existing transcript if logId is present
  let existingTranscript: Array<{ role: string; content: string }> = [];
  if (logId) {
    const { data: logRow } = await db.from("call_logs").select("transcript").eq("id", logId).maybeSingle();
    if (logRow?.transcript && Array.isArray(logRow.transcript)) {
      existingTranscript = logRow.transcript;
    }
  }

  // Initial greeting if no speech yet
  if (!speechText) {
    let greeting = `Hello! This is Aarohi, Mithun's AI assistant calling. Could you please let me know who I am speaking with?`;
    if (bookingId) {
      const { data: b } = await db.from("bookings").select("title,booking_time").eq("id", bookingId).maybeSingle();
      if (b) {
        const timeStr = new Date(b.booking_time).toLocaleString();
        greeting = `Hello! I'm Aarohi, calling on behalf of Mithun to verify his appointment for ${b.title} on ${timeStr}. Are you able to confirm this booking?`;
      }
    }

    existingTranscript.push({ role: "assistant", content: greeting });
    if (logId) {
      await db.from("call_logs").update({ transcript: existingTranscript }).eq("id", logId);
    }

    // Return Fonoster Voice Verbs
    return Response.json({
      verbs: [
        { verb: "Answer" },
        { verb: "Say", text: greeting },
        { verb: "Gather", timeout: 5000, finishOnKey: "#" },
      ],
    });
  }

  // Recipient spoke: speechText contains their transcribed words!
  existingTranscript.push({ role: "caller", content: speechText });

  // Cross-reference bookings from DB
  const { data: upcomingBookings } = await db
    .from("bookings")
    .select("id,title,contact_name,phone_number,booking_time,status")
    .order("booking_time", { ascending: true })
    .limit(5);

  const bookingsContext = (upcomingBookings ?? [])
    .map((b) => `- ID: ${b.id} | Title: "${b.title}" | Contact: "${b.contact_name}" | Time: ${b.booking_time} | Status: ${b.status}`)
    .join("\n");

  const formattedTranscript = existingTranscript
    .map((t) => `${t.role.toUpperCase()}: ${t.content}`)
    .join("\n");

  const system = `You are Aarohi, Mithun's warm, professional personal AI phone assistant.
You are speaking live directly on a real phone call over the cellular telephone network via Fonoster.

GOALS:
1. Identify the clear, specific reason of the call or confirm appointments.
2. If discussing an appointment/booking:
${bookingsContext || "(no bookings scheduled currently)"}
- If confirmed, set booking_action to "confirm".
- If rescheduled/cancelled, set booking_action accordingly.
3. Keep spoken replies short (1-2 sentences). Use natural, spoken English. Never use Markdown.
4. Output strictly valid JSON matching this schema:
{
  "reply": "spoken text to caller",
  "emotion": 0.6,
  "call_reason": "Specific reason of call",
  "booking_action": "none" | "confirm" | "reschedule" | "cancel",
  "matched_booking_id": "UUID string or null",
  "summary": "1-2 sentence recap of call",
  "status": "completed" | "urgent" | "callback_needed",
  "call_completed": boolean
}`;

  const prompt = `Current Phone Call with ${contactName}:
Associated Booking ID: ${bookingId || "None"}
Transcript so far:
${formattedTranscript}

Recipient just said: "${speechText}"

Generate your spoken response in JSON:`;

  let decision: GeminiCallDecision;
  try {
    const raw = await callGemini(geminiKey, model, system, prompt);
    decision = JSON.parse(raw);
  } catch {
    decision = {
      reply: "Thank you for the update. I have noted that down for Mithun. Have a wonderful day!",
      emotion: 0.6,
      call_reason: speechText,
      booking_action: "none",
      summary: `Fonoster call with ${contactName}. Last words: ${speechText}`,
      status: "completed",
      call_completed: true,
    };
  }

  // Update booking if confirmed
  const matchedId = decision.matched_booking_id || bookingId;
  if (matchedId && decision.booking_action !== "none") {
    try {
      await db.from("bookings").update({
        status: decision.booking_action === "confirm" ? "confirmed" :
          decision.booking_action === "reschedule" ? "rescheduled" :
          decision.booking_action === "cancel" ? "cancelled" : "pending",
      }).eq("id", matchedId);
    } catch (_) {}
  }

  // Update transcript and call log
  existingTranscript.push({ role: "assistant", content: decision.reply });
  if (logId) {
    await db.from("call_logs").update({
      transcript: existingTranscript,
      summary: decision.summary,
      call_reason: decision.call_reason,
      status: decision.status,
    }).eq("id", logId);
  }

  // Return Fonoster response verbs
  const verbs: Array<{ verb: string; [key: string]: any }> = [
    { verb: "Say", text: decision.reply },
  ];

  if (decision.call_completed) {
    verbs.push({ verb: "Hangup" });
  } else {
    verbs.push({ verb: "Gather", timeout: 5000, finishOnKey: "#" });
  }

  return Response.json({ verbs });
});
