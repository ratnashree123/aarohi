# Aarohi voice — Chatterbox TTS server (Tier 1 voice).
# Runs on the same laptop as Ollama; the app falls back to on-device TTS
# when this is unreachable or slow, so it is safe for this to be down.
#
# Config (env vars only):
#   TTS_VOICE_REF  path to a ~5s wav of her reference voice (optional;
#                  omit to use Chatterbox's built-in default voice)
#   TTS_PORT       default 8321
#
# Run:  uvicorn chatterbox_server:app --host 0.0.0.0 --port 8321
import io
import os

import torch
import torchaudio
from fastapi import FastAPI
from fastapi.responses import Response
from pydantic import BaseModel

DEVICE = "cuda" if torch.cuda.is_available() else "cpu"
VOICE_REF = os.environ.get("TTS_VOICE_REF")


def load_model():
    # Prefer Turbo (paralinguistic tags: [sigh], [laugh], [chuckle]);
    # fall back to the base model if this chatterbox version lacks it.
    try:
        from chatterbox.tts_turbo import ChatterboxTurboTTS
        return ChatterboxTurboTTS.from_pretrained(device=DEVICE)
    except Exception:
        from chatterbox.tts import ChatterboxTTS
        return ChatterboxTTS.from_pretrained(device=DEVICE)


model = load_model()
app = FastAPI()


class Req(BaseModel):
    text: str
    emotion: float = 0.5  # 0.5 professional … 0.85 dramatic


@app.get("/health")
def health():
    return {"ok": True, "device": DEVICE}


@app.post("/tts")
def tts(r: Req):
    kwargs = dict(exaggeration=max(0.5, min(r.emotion, 0.85)))
    if VOICE_REF:
        kwargs["audio_prompt_path"] = VOICE_REF
    try:
        # cfg_weight low = slower, unrushed pacing (her spec: ~0.85 speed)
        wav = model.generate(r.text, cfg_weight=0.35, **kwargs)
    except TypeError:  # Turbo variants without cfg_weight
        wav = model.generate(r.text, **kwargs)
    buf = io.BytesIO()
    torchaudio.save(buf, wav, model.sr, format="wav")
    return Response(buf.getvalue(), media_type="audio/wav")
