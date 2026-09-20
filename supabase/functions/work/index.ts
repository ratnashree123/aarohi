// Aarohi work mode — ticket text in, macro judgment out. Same provider seam
// as chat: env-var-configured OpenAI-compatible endpoint, everything logged
// to llm_logs (context 'ticket'); the app fills decision/final_output on
// Approve / Edit / Reject. That loop is the F6 fine-tuning dataset.
import { createClient } from "npm:@supabase/supabase-js@2";

const db = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

Deno.serve(async (req) => {
  const { ocr_text } = await req.json();
  if (!ocr_text || typeof ocr_text !== "string") {
    return Response.json({ error: "ocr_text required" }, { status: 400 });
  }

  const { data: macros } = await db.from("macros")
    .select("number,title,body").order("number");
  const macroList = (macros ?? [])
    .map((m) => `#${m.number} — ${m.title}\n${m.body}`)
    .join("\n\n");

  const system =
    `You are Aarohi, helping Mithun (QA/support) handle a ticket. Below are his canned macros. Decide if one fits the ticket; if none fits, draft a reply in a professional, friendly support tone.

MACROS:
${macroList || "(no macros loaded yet)"}

Respond with ONLY a JSON object, no other text:
{"summary": "2-3 plain sentences: what the customer's situation is and what they need",
 "macro_number": <number of the macro that fits, or null>,
 "reasoning": "one sentence on why this macro fits / why none do",
 "reply": "the exact text to send (the macro body, adapted if needed, or your draft)"}

The reply must be plain professional text — no stage directions or bracketed tags like [sigh].`;

async function callGeminiWork(
  apiKey: string,
  model: string,
  system: string,
  ocrText: string,
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
      contents: [
        {
          role: "user",
          parts: [{ text: ocrText }],
        },
      ],
      generationConfig: {
        maxOutputTokens: 2048,
        temperature: 0.2,
        responseMimeType: "application/json",
      },
    }),
    signal: AbortSignal.timeout(30_000),
  });

  if (!res.ok) {
    const errText = await res.text();
    throw new Error(`Gemini API ${res.status}: ${errText}`);
  }
  const data = await res.json();
  const parts = data.candidates?.[0]?.content?.parts ?? [];
  const textPart = parts.find((p: any) => p.text && !p.thought) ?? parts[0];
  return textPart?.text ?? "";
}

async function callOpenAICompatWork(
  base: string,
  key: string | undefined,
  model: string,
  system: string,
  ocrText: string,
): Promise<string> {
  const res = await fetch(`${base.replace(/\/$/, "")}/chat/completions`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      ...(key ? { authorization: `Bearer ${key}` } : {}),
    },
    body: JSON.stringify({
      model,
      max_tokens: 2048,
      response_format: { type: "json_object" },
      messages: [{ role: "system", content: system }, { role: "user", content: ocrText }],
    }),
    signal: AbortSignal.timeout(30_000),
  });
  if (!res.ok) throw new Error(`LLM ${res.status}: ${await res.text()}`);
  const data = await res.json();
  return data.choices?.[0]?.message?.content ?? "";
}

  const input = [{ role: "user", content: ocr_text }];
  const geminiKey = Deno.env.get("GEMINI_API_KEY");
  const provider = Deno.env.get("LLM_PROVIDER") ?? (geminiKey ? "gemini" : "gemini");
  const model = Deno.env.get("LLM_MODEL") ?? (provider === "gemini" ? "gemini-3.5-flash-lite" : "gemini-3.5-flash-lite");

  const started = Date.now();
  let raw: string;
  try {
    if (geminiKey || provider === "gemini") {
      const key = geminiKey || Deno.env.get("LLM_API_KEY");
      if (!key) throw new Error("GEMINI_API_KEY or LLM_API_KEY required for Gemini");
      raw = await callGeminiWork(key, model, system, ocr_text);
    } else {
      const base = Deno.env.get("LLM_BASE_URL");
      if (!base) throw new Error("LLM_BASE_URL not set");
      const key = Deno.env.get("LLM_API_KEY");
      raw = await callOpenAICompatWork(base, key, model, system, ocr_text);
    }
  } catch (e) {
    console.error("LLM unreachable:", e);
    return Response.json({ offline: true, error: String(e) });
  }
  const latency = Date.now() - started;

  // Small local models don't always obey "JSON only" — salvage what we can.
  let parsed: {
    summary?: string;
    macro_number?: number | null;
    reasoning?: string;
    reply?: string;
  };
  try {
    parsed = JSON.parse(raw.replace(/^```(?:json)?\s*|\s*```$/g, "").trim());
  } catch {
    parsed = { summary: "", macro_number: null, reasoning: "", reply: raw };
  }

  const { data: log } = await db.from("llm_logs").insert({
    provider,
    model,
    context: "ticket",
    system_prompt: system,
    input_messages: input,
    raw_output: raw,
    latency_ms: latency,
  }).select("id").single();

  return Response.json({
    log_id: log?.id,
    summary: parsed.summary ?? "",
    macro_number: parsed.macro_number ?? null,
    reasoning: parsed.reasoning ?? "",
    reply: parsed.reply ?? raw,
  });
});
