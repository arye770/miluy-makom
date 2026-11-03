// Reads an uploaded file (text or images) with Claude and returns its JSON answer.
// Only signed-in users with the editor or admin role may call it.
// Needs the secret ANTHROPIC_API_KEY (Supabase: Edge Functions -> Secrets).
import Anthropic from "npm:@anthropic-ai/sdk";
import { createClient } from "npm:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const reply = (body, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });

  const sb = createClient(Deno.env.get("SUPABASE_URL"), Deno.env.get("SUPABASE_ANON_KEY"), {
    global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
  });
  const { data: role } = await sb.rpc("my_role");
  if (role !== "editor" && role !== "admin") return reply({ error: "not_allowed" }, 403);

  const body = await req.json().catch(() => ({}));
  const hasKey = !!Deno.env.get("ANTHROPIC_API_KEY");
  if (body.ping) return reply({ ready: hasKey });
  if (!hasKey) return reply({ error: "no_key" }, 503);

  const content = [];
  for (const im of (body.images || []).slice(0, 8)) {
    content.push({ type: "image", source: { type: "base64", media_type: im.type, data: im.data } });
  }
  content.push({ type: "text", text: String(body.prompt || "") + "\n\nReply with the JSON only." });

  const client = new Anthropic();
  try {
    const msg = await client.beta.messages.create({
      model: "claude-opus-5-5",
      max_tokens: 16000,
      betas: ["server-side-fallback-2026-07-01"],
      fallbacks: "default",
      messages: [{ role: "user", content }],
    });
    if (msg.stop_reason === "refusal") return reply({ error: "refusal" }, 422);
    const text = msg.content.filter((b) => b.type === "text").map((b) => b.text).join("");
    return reply({ text, truncated: msg.stop_reason === "max_tokens" });
  } catch (e) {
    if (e instanceof Anthropic.RateLimitError) return reply({ error: "rate_limited" }, 429);
    if (e instanceof Anthropic.AuthenticationError) return reply({ error: "bad_key" }, 503);
    if (e instanceof Anthropic.APIError) return reply({ error: "api_error", message: e.message }, 502);
    return reply({ error: "api_error", message: String(e?.message || e) }, 502);
  }
});
