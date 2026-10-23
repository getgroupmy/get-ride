/**
 * One request to the AI service set up in Admin -> Fare AI / API Keys (app
 * setting `fare_ai_provider`): Google's, Anthropic's or one of the
 * OpenAI-compatible chat APIs. Moved here from ai-route-proxy so the
 * Reports function (ai-report) asks the same way with the same keys.
 *
 * Plain fetch, with a stand-in for tests.
 *
 *     deno test supabase/functions/_shared/ai_providers_test.ts
 */

export type Provider =
  | "gemini"
  | "grok"
  | "chatgpt"
  | "groq"
  | "claude"
  | "perplexity"
  | "mistral"
  | "deepseek"
  | "cohere"
  | "together"
  | "openrouter"
  | "fireworks";

export interface FareAIKey {
  id: string;
  label: string;
  key: string;
  enabled: boolean;
}

/** The parts of the `fare_ai_provider` setting every caller reads. */
export interface AIServiceConfig {
  serviceEnabled?: boolean;
  provider?: Provider;
  models?: Partial<Record<Provider, string>>;
  keys?: Partial<Record<Provider, FareAIKey[]>>;
}

export interface CallResult {
  content: string | null;
  httpStatus: number | null;
  error: string | null;
}

/** How the question is asked. */
export interface AskOptions {
  systemInstruction: string;
  temperature: number;
  /** Anthropic's API needs a cap; the others use their own limit. */
  maxTokens: number;
}

export const DEFAULT_MODELS: Record<Provider, string> = {
  gemini: "gemini-2.5-flash",
  grok: "grok-3",
  chatgpt: "gpt-4o-mini",
  groq: "llama-3.3-70b-versatile",
  claude: "claude-3-5-haiku-latest",
  perplexity: "sonar",
  mistral: "mistral-small-latest",
  deepseek: "deepseek-chat",
  cohere: "command-r",
  together: "meta-llama/Llama-3.3-70B-Instruct-Turbo",
  openrouter: "openai/gpt-4o-mini",
  fireworks: "accounts/fireworks/models/llama-v3p3-70b-instruct",
};

/** The provider, model and usable keys of a saved setting. */
export function serviceOf(config: AIServiceConfig | null | undefined): {
  provider: Provider;
  model: string;
  keys: FareAIKey[];
} {
  const c = config ?? {};
  const provider: Provider = c.provider && c.provider in DEFAULT_MODELS ? c.provider : "gemini";
  const model = c.models?.[provider] ?? DEFAULT_MODELS[provider];
  const keys = (c.keys?.[provider] ?? []).filter(
    (k) => k && k.enabled !== false && typeof k.key === "string" && k.key.trim().length > 0,
  );
  return { provider, model, keys };
}

async function callOpenAICompatible(
  endpoint: string,
  apiKey: string,
  model: string,
  prompt: string,
  label: string,
  req: AskOptions,
  fetchFn: typeof fetch,
): Promise<CallResult> {
  const response = await fetchFn(endpoint, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${apiKey}`,
    },
    body: JSON.stringify({
      model,
      temperature: req.temperature,
      response_format: { type: "json_object" },
      messages: [
        { role: "system", content: req.systemInstruction },
        { role: "user", content: prompt },
      ],
    }),
  });
  if (!response.ok) {
    const errText = await response.text();
    return {
      content: null,
      httpStatus: response.status,
      error: `${label} HTTP ${response.status}: ${errText.substring(0, 200)}`,
    };
  }
  const data = await response.json();
  const content: string | undefined = data?.choices?.[0]?.message?.content;
  return {
    content: content ?? null,
    httpStatus: response.status,
    error: content ? null : "Empty content",
  };
}

async function callGemini(
  prompt: string,
  apiKey: string,
  model: string,
  req: AskOptions,
  fetchFn: typeof fetch,
): Promise<CallResult> {
  const endpoint =
    `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${apiKey}`;
  const response = await fetchFn(endpoint, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      systemInstruction: { parts: [{ text: req.systemInstruction }] },
      contents: [{ role: "user", parts: [{ text: prompt }] }],
      generationConfig: { temperature: req.temperature, responseMimeType: "application/json" },
    }),
  });
  if (!response.ok) {
    const errText = await response.text();
    return {
      content: null,
      httpStatus: response.status,
      error: `HTTP ${response.status}: ${errText.substring(0, 200)}`,
    };
  }
  const data = await response.json();
  const content: string | undefined = data?.candidates?.[0]?.content?.parts?.[0]?.text;
  return {
    content: content ?? null,
    httpStatus: response.status,
    error: content ? null : "Empty content",
  };
}

async function callAnthropic(
  prompt: string,
  apiKey: string,
  model: string,
  req: AskOptions,
  fetchFn: typeof fetch,
): Promise<CallResult> {
  const response = await fetchFn("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-api-key": apiKey,
      "anthropic-version": "2023-06-01",
    },
    body: JSON.stringify({
      model,
      // Claude requires a cap; the others use their own limit.
      max_tokens: req.maxTokens,
      temperature: req.temperature,
      system: req.systemInstruction,
      messages: [{ role: "user", content: prompt }],
    }),
  });
  if (!response.ok) {
    const errText = await response.text();
    return {
      content: null,
      httpStatus: response.status,
      error: `Claude HTTP ${response.status}: ${errText.substring(0, 200)}`,
    };
  }
  const data = await response.json();
  const content: string | undefined = data?.content?.[0]?.text;
  return {
    content: content ?? null,
    httpStatus: response.status,
    error: content ? null : "Empty content",
  };
}

export function callProvider(
  provider: Provider,
  prompt: string,
  apiKey: string,
  model: string,
  req: AskOptions,
  fetchFn: typeof fetch = fetch,
): Promise<CallResult> {
  const compat = (endpoint: string, label: string) =>
    callOpenAICompatible(endpoint, apiKey, model, prompt, label, req, fetchFn);
  switch (provider) {
    case "grok":
      return compat("https://api.x.ai/v1/chat/completions", "Grok");
    case "chatgpt":
      return compat("https://api.openai.com/v1/chat/completions", "ChatGPT");
    case "groq":
      return compat("https://api.groq.com/openai/v1/chat/completions", "Groq");
    case "perplexity":
      return compat("https://api.perplexity.ai/chat/completions", "Perplexity");
    case "mistral":
      return compat("https://api.mistral.ai/v1/chat/completions", "Mistral");
    case "deepseek":
      return compat("https://api.deepseek.com/chat/completions", "DeepSeek");
    case "cohere":
      return compat("https://api.cohere.ai/compatibility/v1/chat/completions", "Cohere");
    case "together":
      return compat("https://api.together.xyz/v1/chat/completions", "Together AI");
    case "openrouter":
      return compat("https://openrouter.ai/api/v1/chat/completions", "OpenRouter");
    case "fireworks":
      return compat("https://api.fireworks.ai/inference/v1/chat/completions", "Fireworks");
    case "claude":
      return callAnthropic(prompt, apiKey, model, req, fetchFn);
    case "gemini":
    default:
      return callGemini(prompt, apiKey, model, req, fetchFn);
  }
}

/** The first JSON object in an answer, fences and words around it dropped. */
export function jsonObjectIn(content: string): Record<string, unknown> | null {
  const cleaned = content.replace(/```json/gi, "").replace(/```/g, "").trim();
  const match = cleaned.match(/\{[\s\S]*\}/);
  if (!match) return null;
  try {
    const v = JSON.parse(match[0]);
    return v && typeof v === "object" && !Array.isArray(v) ? v as Record<string, unknown> : null;
  } catch {
    return null;
  }
}
