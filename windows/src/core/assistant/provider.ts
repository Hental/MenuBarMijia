

// MARK: - Provider presets and endpoint policy

export interface AssistantProviderPresetInfo {
  readonly id: string;
  readonly title: string;
  readonly shortTitle: string;
  readonly defaultBaseURL: string;
  readonly defaultModel: string;
  readonly keyPlaceholder: string;
}

export const ASSISTANT_PROVIDER_PRESETS: ReadonlyArray<AssistantProviderPresetInfo> = [
  {
    id: "openrouter_jev",
    title: "OpenRouter · Jev (默认)",
    shortTitle: "OpenRouter",
    defaultBaseURL: "https://openrouter.ai/api/v1",
    defaultModel: "~typesafe/jev-latest",
    keyPlaceholder: "sk-or-v1-...",
  },
  {
    id: "native_jev",
    title: "TypeSafe · 原生 Jev",
    shortTitle: "原生 Jev",
    defaultBaseURL: "https://api.typesafe.ai/v1",
    defaultModel: "jev-latest",
    keyPlaceholder: "粘贴 TypeSafe 原生 Jev API Key",
  },
  {
    id: "deepseek",
    title: "DeepSeek 官方",
    shortTitle: "DeepSeek",
    defaultBaseURL: "https://api.deepseek.com/v1",
    defaultModel: "deepseek-chat",
    keyPlaceholder: "粘贴 DeepSeek API Key (sk-...)",
  },
  {
    id: "siliconflow",
    title: "硅基流动 SiliconFlow",
    shortTitle: "硅基流动",
    defaultBaseURL: "https://api.siliconflow.cn/v1",
    defaultModel: "deepseek-ai/DeepSeek-V3",
    keyPlaceholder: "粘贴硅基流动 API Key (sk-...)",
  },
  {
    id: "dashscope",
    title: "通义千问 / 阿里云百炼",
    shortTitle: "通义千问",
    defaultBaseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
    defaultModel: "qwen-plus",
    keyPlaceholder: "粘贴百炼 DashScope API Key (sk-...)",
  },
  {
    id: "zhipu_glm",
    title: "智谱 GLM (BigModel)",
    shortTitle: "智谱 GLM",
    defaultBaseURL: "https://open.bigmodel.cn/api/paas/v4",
    defaultModel: "glm-4-flash",
    keyPlaceholder: "粘贴智谱开放平台 API Key",
  },
  {
    id: "moonshot_kimi",
    title: "Moonshot Kimi (月之暗面)",
    shortTitle: "Kimi",
    defaultBaseURL: "https://api.moonshot.cn/v1",
    defaultModel: "kimi-k2-0711-preview",
    keyPlaceholder: "粘贴 Moonshot Kimi API Key (sk-...)",
  },
  {
    id: "openai",
    title: "OpenAI",
    shortTitle: "OpenAI",
    defaultBaseURL: "https://api.openai.com/v1",
    defaultModel: "gpt-4o-mini",
    keyPlaceholder: "粘贴 OpenAI API Key (sk-...)",
  },
  {
    id: "gemini",
    title: "Google Gemini",
    shortTitle: "Gemini",
    defaultBaseURL: "https://generativelanguage.googleapis.com/v1beta/openai",
    defaultModel: "gemini-2.5-flash",
    keyPlaceholder: "粘贴 Google Gemini API Key (AIza...)",
  },
  {
    id: "groq",
    title: "Groq",
    shortTitle: "Groq",
    defaultBaseURL: "https://api.groq.com/openai/v1",
    defaultModel: "llama-3.3-70b-versatile",
    keyPlaceholder: "粘贴 Groq API Key (gsk_...)",
  },
  {
    id: "ollama",
    title: "Ollama 本地模型",
    shortTitle: "Ollama",
    defaultBaseURL: "http://localhost:11434/v1",
    defaultModel: "qwen2.5:7b",
    keyPlaceholder: "Ollama 本地接口免密（可留空）",
  },
  {
    id: "custom",
    title: "自定义兼容接口",
    shortTitle: "自定义",
    defaultBaseURL: "",
    defaultModel: "",
    keyPlaceholder: "粘贴 API Key (本机接口可留空)",
  },
];

export interface AssistantEndpoint {
  readonly scheme: "http" | "https";
  /** Lowercased host without IPv6 brackets or a trailing dot. */
  readonly host: string;
  readonly port: number | null;
}

/** Parses a user-typed endpoint. A missing scheme means https (`api.deepseek.com/v1`). Mirrors macOS `AssistantEndpoint`. */
export function parseAssistantEndpoint(raw: string): AssistantEndpoint | null {
  let text = raw.trim();
  if (!text) return null;
  if (!text.includes("://")) text = `https://${text}`;
  let url: URL;
  try {
    url = new URL(text);
  } catch {
    return null;
  }
  const scheme = url.protocol.replace(/:$/, "").toLowerCase();
  if (scheme !== "http" && scheme !== "https") return null;
  let host = url.hostname.toLowerCase();
  if (host.startsWith("[") && host.endsWith("]")) host = host.slice(1, -1);
  host = host.replace(/\.+$/, "");
  if (!host) return null;
  return { scheme, host, port: url.port ? Number(url.port) : null };
}

/** `domain` itself or one of its subdomains: `api.openrouter.ai` matches, `openrouter.ai.evil.com` does not. */
export function endpointHostMatches(endpoint: AssistantEndpoint, domain: string): boolean {
  return endpoint.host === domain || endpoint.host.endsWith(`.${domain}`);
}

/** Four dotted decimal octets, or null when `host` is not an IPv4 literal (so `10.evil.com` is not a LAN address). */
export function ipv4Octets(host: string): number[] | null {
  const parts = host.split(".");
  if (parts.length !== 4) return null;
  const octets: number[] = [];
  for (const part of parts) {
    if (!/^[0-9]{1,3}$/.test(part)) return null;
    const value = Number(part);
    if (value > 255) return null;
    octets.push(value);
  }
  return octets;
}

/** Loopback, private LAN, link-local, CGNAT/Tailscale, IPv6 ULA/link-local, or mDNS `.local` names. */
export function isLocalNetworkEndpoint(endpoint: AssistantEndpoint): boolean {
  const host = endpoint.host;
  if (host === "localhost" || host === "::1" || host.endsWith(".local")) return true;
  const octets = ipv4Octets(host);
  if (octets) {
    const [a, b] = octets as [number, number, number, number];
    return (
      a === 127 ||
      a === 10 ||
      (a === 192 && b === 168) ||
      (a === 169 && b === 254) ||
      (a === 172 && b >= 16 && b <= 31) ||
      (a === 100 && b >= 64 && b <= 127)
    );
  }
  if (host.includes(":")) {
    return /^(fc|fd|fe[89ab])/.test(host);
  }
  return false;
}

/** API keys only travel over https, or over plain http that stays on the local network. */
export function endpointAllowsSendingSecrets(baseURL: string): boolean {
  const endpoint = parseAssistantEndpoint(baseURL);
  if (!endpoint) return false;
  return endpoint.scheme === "https" || isLocalNetworkEndpoint(endpoint);
}

/** True when the endpoint may run without an API key (this computer or the local network). */
export function isLocalAssistantEndpoint(baseURL: string): boolean {
  const endpoint = parseAssistantEndpoint(baseURL);
  return endpoint ? isLocalNetworkEndpoint(endpoint) : false;
}

/** Host plus explicit port; a saved key is bound to this value. */
export function assistantEndpointIdentity(baseURL: string): string | null {
  const endpoint = parseAssistantEndpoint(baseURL);
  if (!endpoint) return null;
  if (endpoint.port === null) return endpoint.host;
  return endpoint.host.includes(":") ? `[${endpoint.host}]:${endpoint.port}` : `${endpoint.host}:${endpoint.port}`;
}

function presetById(id: string): AssistantProviderPresetInfo {
  return ASSISTANT_PROVIDER_PRESETS.find((p) => p.id === id) ?? ASSISTANT_PROVIDER_PRESETS[ASSISTANT_PROVIDER_PRESETS.length - 1]!;
}

/**
 * Maps an endpoint to its provider by exact host (or a subdomain of a provider-owned domain).
 * Substring checks would also match `openrouter.ai.evil.com`. Shared cases: Tests/Fixtures/provider_golden.json.
 */
export function inferAssistantPreset(baseURL: string): AssistantProviderPresetInfo {
  const endpoint = parseAssistantEndpoint(baseURL);
  if (!endpoint) return presetById("custom");
  const host = endpoint.host;
  const is = (domain: string) => endpointHostMatches(endpoint, domain);
  if (is("openrouter.ai")) return presetById("openrouter_jev");
  if (is("typesafe.ai")) return presetById("native_jev");
  if (is("deepseek.com")) return presetById("deepseek");
  if (is("siliconflow.cn")) return presetById("siliconflow");
  // aliyuncs.com and googleapis.com also serve customer-owned buckets, so only the API hosts count.
  if (host === "dashscope.aliyuncs.com" || host === "dashscope-intl.aliyuncs.com") return presetById("dashscope");
  if (is("bigmodel.cn")) return presetById("zhipu_glm");
  if (is("moonshot.cn") || is("moonshot.ai")) return presetById("moonshot_kimi");
  if (is("openai.com")) return presetById("openai");
  if (host === "generativelanguage.googleapis.com") return presetById("gemini");
  if (is("groq.com")) return presetById("groq");
  if (endpoint.port === 11434 && isLocalNetworkEndpoint(endpoint)) return presetById("ollama");
  return presetById("custom");
}

export interface AssistantConfig {
  readonly baseURL: string;
  readonly model: string;
  readonly apiKey: string;
}

export const DEFAULT_ASSISTANT_CONFIG: AssistantConfig = {
  baseURL: "https://openrouter.ai/api/v1",
  model: "~typesafe/jev-latest",
  apiKey: "",
};

/** Shown when a plain-http public endpoint would receive the API key and the user's words unencrypted (#19). */
export const INSECURE_ENDPOINT_MESSAGE =
  "AI 服务地址不是 https。为保护 API Key，只有本机或局域网地址可以用 http。";
