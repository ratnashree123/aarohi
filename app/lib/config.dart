// Fill these from your Supabase project (Settings → API).
// The anon key is safe to ship in the app; the Anthropic key lives only in
// the Edge Function secrets.
class Config {
  static const supabaseUrl = 'https://wpmwnsgfjexgegusvaah.supabase.co';
  static const supabaseKey = 'sb_publishable_xqgvhc-XFiwf_BpODS1RVQ_mOE8_sgt';

  // Cloud AI: empty string = fast on-device feminine voice (no laptop lag)
  static const ttsBaseUrl = '';
}
