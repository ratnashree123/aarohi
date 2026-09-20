// Aarohi Twilio Voice Agent — Real Outbound & Inbound Cellular Calling
// Connects Google Gemini 3.5 Flash Lite + Amazon Polly / Google Neural Voices
// over Twilio Cloud Telephony to place real telephone calls to mobile numbers.
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

function escapeXml(unsafe: string): string {
  return unsafe.replace(/[<>&'"]/g, (c) => {
    switch (c) {
      case "<": return "&lt;";
      case ">": return "&gt;";
      case "&": return "&amp;";
      case "'": return "&apos;";
      case '"': return "&quot;";
      default: return c;
    }
  });
}

function buildTwimlResponse(reply: string, nextActionUrl?: string, callCompleted: boolean = false): string {
  const cleanReply = escapeXml(reply);
  if (callCompleted || !nextActionUrl) {
    return `<?xml version="1.0" encoding="UTF-8"?>
<Response>
  <Say voice="Polly.Aditi" language="en-IN">${cleanReply}</Say>
  <Hangup/>
</Response>`;
  }

  return `<?xml version="1.0" encoding="UTF-8"?>
<Response>
  <Gather input="speech" action="${escapeXml(nextActionUrl)}" method="POST" speechTimeout="auto" language="en-IN" timeout="5">
    <Say voice="Polly.Aditi" language="en-IN">${cleanReply}</Say>
  </Gather>
  <Say voice="Polly.Aditi" language="en-IN">I didn&apos;t catch that. Please feel free to call back. Goodbye!</Say>
  <Hangup/>
</Response>`;
}

Deno.serve(async (req) => {
  const url = new URL(req.url);
  const supabaseUrl = Deno.env.get("SUPABASE_URL") || "";
  const geminiKey = Deno.env.get("GEMINI_API_KEY") || Deno.env.get("LLM_API_KEY") || "";
  const model = Deno.env.get("LLM_MODEL") ?? "gemini-3.5-flash-lite";

  // Configuration check endpoint
  if (url.searchParams.get("action") === "status") {
    const hasSid = !!(Deno.env.get("TWILIO_ACCOUNT_SID"));
    const hasAuth = !!(Deno.env.get("TWILIO_AUTH_TOKEN"));
    const hasNumber = !!(Deno.env.get("TWILIO_PHONE_NUMBER"));
    return Response.json({
      configured: hasSid && hasAuth && hasNumber,
      has_sid: hasSid,
      has_auth: hasAuth,
      has_number: hasNumber,
      phone_number: Deno.env.get("TWILIO_PHONE_NUMBER") || null,
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

      const twilioSid = body.twilio_sid || Deno.env.get("TWILIO_ACCOUNT_SID");
      const twilioAuth = body.twilio_auth || Deno.env.get("TWILIO_AUTH_TOKEN");
      const twilioFrom = body.twilio_number || Deno.env.get("TWILIO_PHONE_NUMBER");

      if (!twilioSid || !twilioAuth || !twilioFrom) {
        return Response.json({
          error: "Twilio credentials missing. Please set TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN, and TWILIO_PHONE_NUMBER.",
          requires_config: true,
        }, { status: 400 });
      }

      if (!to) {
        return Response.json({ error: "Missing 'to' phone number" }, { status: 400 });
      }

      // 1. Create call log row in Supabase
      const { data: logEntry, error: logErr } = await db.from("call_logs").insert({
        caller_name: contactName,
        caller_phone: to,
        direction: "outbound",
        call_reason: "Twilio real cellular call initiated",
        transcript: [],
        status: "urgent",
      }).select("id").single();

      const logId = logEntry?.id;

      // 2. Trigger Twilio Outbound Call API
      const webhookUrl = `${supabaseUrl}/functions/v1/twilio_voice?log_id=${logId || ""}&booking_id=${bookingId || ""}&name=${encodeURIComponent(contactName)}&to=${encodeURIComponent(to)}`;
      const statusCallbackUrl = `${supabaseUrl}/functions/v1/twilio_voice?action=call_completed&log_id=${logId || ""}`;

      const params = new URLSearchParams();
      params.append("To", to);
      params.append("From", twilioFrom);
      params.append("Url", webhookUrl);
      params.append("StatusCallback", statusCallbackUrl);
      params.append("StatusCallbackEvent", "completed");

      const twilioEndpoint = `https://api.twilio.com/2010-04-01/Accounts/${twilioSid}/Calls.json`;
      const authHeader = "Basic " + btoa(`${twilioSid}:${twilioAuth}`);

      const twilioRes = await fetch(twilioEndpoint, {
        method: "POST",
        headers: {
          "Authorization": authHeader,
          "Content-Type": "application/x-www-form-urlencoded",
        },
        body: params.toString(),
      });

      const twilioData = await twilioRes.json();
      if (!twilioRes.ok) {
        return Response.json({
          error: twilioData.message || "Twilio call failed to initiate",
          details: twilioData,
        }, { status: 400 });
      }

      return Response.json({
        success: true,
        call_sid: twilioData.sid,
        log_id: logId,
        status: twilioData.status,
        message: `Twilio is dialing ${to} over the cellular network!`,
      });
    }
  }

  // Handle Twilio Webhooks (application/x-www-form-urlencoded)
  const formData = await req.formData().catch(() => new FormData());
  const speechResult = formData.get("SpeechResult")?.toString() || "";
  const callSid = formData.get("CallSid")?.toString() || "";
  const logId = url.searchParams.get("log_id");
  const bookingId = url.searchParams.get("booking_id");
  const contactName = url.searchParams.get("name") || "Friend";
  const toPhone = url.searchParams.get("to") || "";

  // Call completion status callback
  if (url.searchParams.get("action") === "call_completed") {
    if (logId) {
      const duration = formData.get("CallDuration")?.toString() || "0";
      await db.from("call_logs").update({
        status: "completed",
        call_reason: `Cellular call completed (${duration}s)`,
      }).eq("id", logId);
    }
    return new Response("<Response/>", { headers: { "Content-Type": "text/xml" } });
  }

  // Load existing transcript if logId is present
  let existingTranscript: Array<{ role: string; content: string }> = [];
  if (logId) {
    const { data: logRow } = await db.from("call_logs").select("transcript").eq("id", logId).maybeSingle();
    if (logRow?.transcript && Array.isArray(logRow.transcript)) {
      existingTranscript = logRow.transcript;
    }
  }

  // If no speech input yet: Recipient just picked up the phone call!
  if (!speechResult) {
    let initialGreeting = `Hello! I'm Aarohi, Mithun's AI assistant calling. Could you please let me know who I am speaking with?`;

    if (bookingId) {
      const { data: b } = await db.from("bookings").select("title,booking_time,contact_name")
        .eq("id", bookingId).maybeSingle();
      if (b) {
        const timeStr = new Date(b.booking_time).toLocaleString();
        initialGreeting = `Hello! I'm Aarohi, calling on behalf of Mithun to verify his appointment for ${b.title} on ${timeStr}. Are you able to confirm this booking?`;
      }
    }

    // Save initial greeting to transcript
    existingTranscript.push({ role: "assistant", content: initialGreeting });
    if (logId) {
      await db.from("call_logs").update({ transcript: existingTranscript }).eq("id", logId);
    }

    const nextUrl = `${supabaseUrl}/functions/v1/twilio_voice?log_id=${logId || ""}&booking_id=${bookingId || ""}&name=${encodeURIComponent(contactName)}&to=${encodeURIComponent(toPhone)}`;
    const twiml = buildTwimlResponse(initialGreeting, nextUrl, false);
    return new Response(twiml, { headers: { "Content-Type": "text/xml" } });
  }

  // Recipient spoke: speechResult contains their words transcribed by Twilio!
  existingTranscript.push({ role: "caller", content: speechResult });

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

  const system = `You are Aarohi, Mithun's warm, professional, and articulate personal AI phone assistant.
You are speaking live directly on a real phone call over the cellular telephone network with a human.

GOALS:
1. Identify the clear, specific reason of the call or confirm appointments.
2. If discussing an appointment/booking:
${bookingsContext || "(no bookings scheduled currently)"}
- If they confirm the appointment, warmly acknowledge and set booking_action to "confirm".
- If they request reschedule or cancel, acknowledge and set booking_action accordingly.
3. Keep spoken replies short (1-2 sentences max). Use conversational spoken English. Never use Markdown or bracketed tags.
4. Output strictly valid JSON matching this schema:
{
  "reply": "spoken text to the person on the call",
  "emotion": 0.6,
  "call_reason": "Specific reason why the person called or answered",
  "booking_action": "none" | "confirm" | "reschedule" | "cancel",
  "matched_booking_id": "UUID string if matches a booking, else null",
  "summary": "1-2 sentence recap of the call",
  "status": "completed" | "urgent" | "callback_needed",
  "call_completed": boolean // true if caller said goodbye, thanks, or conversation is wrapped
}`;

  const prompt = `Current Phone Call:
Recipient Name: ${contactName}
Phone Number: ${toPhone}
Associated Booking ID: ${bookingId || "None"}

Transcript so far:
${formattedTranscript}

Recipient just said: "${speechResult}"

Generate your spoken response in JSON:`;

  let decision: GeminiCallDecision;
  try {
    const raw = await callGemini(geminiKey, model, system, prompt);
    decision = JSON.parse(raw);
  } catch (err) {
    console.error("Gemini call error:", err);
    decision = {
      reply: "Thank you for the update. I have noted that down for Mithun. Have a wonderful day!",
      emotion: 0.6,
      call_reason: speechResult,
      booking_action: "none",
      summary: `Cellular call with ${contactName}. Last words: ${speechResult}`,
      status: "completed",
      call_completed: true,
    };
  }

  // Update booking status if confirmed
  const matchedId = decision.matched_booking_id || bookingId;
  if (matchedId && decision.booking_action !== "none") {
    try {
      await db.from("bookings").update({
        status: decision.booking_action === "confirm" ? "confirmed" :
          decision.booking_action === "reschedule" ? "rescheduled" :
          decision.booking_action === "cancel" ? "cancelled" : "pending",
      }).eq("id", matchedId);
    } catch (e) {
      console.error("Error updating booking:", e);
    }
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

  const nextUrl = `${supabaseUrl}/functions/v1/twilio_voice?log_id=${logId || ""}&booking_id=${bookingId || ""}&name=${encodeURIComponent(contactName)}&to=${encodeURIComponent(toPhone)}`;
  const twiml = buildTwimlResponse(decision.reply, nextUrl, decision.call_completed);

  return new Response(twiml, { headers: { "Content-Type": "text/xml" } });
});
