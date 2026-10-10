const allowed = new Set(['/tools/catalog', '/tools/run', '/sessions/close', '/runtime/status', '/runtime/checkpoint']);

export async function routeGaryRequest(request, env) {
  const url = new URL(request.url);
  if (!allowed.has(url.pathname)) return Response.json({ ok: false, error: 'Unknown Gary endpoint.' }, { status: 404 });
  if (request.method !== 'POST' || request.headers.has('Origin')) return Response.json({ ok: false, error: 'Private POST requests are required.' }, { status: 403 });
  if (!env.GARY_CONTAINER || String(env.GARY_RUNTIME_TOKEN || '').length < 24 || !env.GARY_STATE) return Response.json({ ok: false, error: 'Gary backend bindings and secrets are not configured.' }, { status: 503 });
  const body = await request.text();
  if (body.length > 1048576) return Response.json({ ok: false, error: 'Gary request exceeds 1 MiB.' }, { status: 413 });
  try {
    const data = JSON.parse(body);
    if (!data || typeof data !== 'object' || Array.isArray(data)) throw new Error('JSON object required.');
    const id = env.GARY_CONTAINER.idFromName('garrett');
    return await env.GARY_CONTAINER.get(id).fetch(new Request('http://gary-container' + url.pathname, {
      method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: 'Bearer ' + env.GARY_RUNTIME_TOKEN }, body, signal: request.signal,
    }));
  } catch (error) { return Response.json({ ok: false, error: error.message }, { status: 502 }); }
}

export async function runGaryAI(request, env) {
  if (request.method !== 'POST' || new URL(request.url).pathname !== '/v1/chat/completions') return new Response('Not found', { status: 404 });
  const text = await request.text();
  if (text.length > 1048576) return new Response('Request too large', { status: 413 });
  const body = JSON.parse(text);
  if (!Array.isArray(body.messages)) return new Response('Messages required', { status: 400 });
  const model = env.GARY_LLM_MODEL || '@cf/zai-org/glm-4.7-flash';
  let result;
  try { result = await env.AI.run(model, {
    messages: body.messages,
    ...(body.tools ? { tools: body.tools.map(t => t.function ? t : {type:'function',function:t}) } : {}),
    max_tokens: Math.min(Math.max(Number(body.max_tokens || body.max_completion_tokens) || 4096, 1), 16384),
    temperature: Number.isFinite(body.temperature) ? body.temperature : 0.2,
    stream: false,
    ...(body.tool_choice ? {tool_choice:body.tool_choice} : {}),
    chat_template_kwargs: body.chat_template_kwargs && typeof body.chat_template_kwargs === 'object' ? body.chat_template_kwargs : {enable_thinking:body.thinking?.type === 'enabled' || ['low','medium','high'].includes(body.reasoning_effort)},
  }); } catch (error) {
    return Response.json({error:{message:error.message,type:'gary_ai_error'}},{status:502});
  }
  const calls = (result.tool_calls || []).map((call, i) => ({
    id: call.id || `gary_${Date.now()}_${i}`, type: 'function',
    function: { name: call.function?.name || call.name, arguments: typeof (call.function?.arguments || call.arguments) === 'string' ? (call.function?.arguments || call.arguments) : JSON.stringify(call.function?.arguments || call.arguments || {}) },
  }));
  const completion = Array.isArray(result.choices) ? result : {
    id: 'gary_' + crypto.randomUUID(), object: 'chat.completion', created: Math.floor(Date.now() / 1000), model,
    choices: [{ index: 0, message: { role: 'assistant', content: result.response || '', ...(calls.length ? { tool_calls: calls } : {}) }, finish_reason: calls.length ? 'tool_calls' : 'stop' }],
    usage: result.usage || { prompt_tokens: 0, completion_tokens: 0, total_tokens: 0 },
  };
  if (!body.stream) return Response.json(completion);
  const chunks = completion.choices.flatMap(choice => [
    { id: completion.id, object: 'chat.completion.chunk', created: completion.created, model, choices: [{ index: choice.index || 0, delta: { ...choice.message, ...(choice.message.tool_calls ? { tool_calls: choice.message.tool_calls.map((call, index) => ({ ...call, index })) } : {}) }, finish_reason: null }] },
    { id: completion.id, object: 'chat.completion.chunk', created: completion.created, model, choices: [{ index: choice.index || 0, delta: {}, finish_reason: choice.finish_reason || 'stop' }] },
  ]);
  if (completion.usage) chunks.push({ id: completion.id, object: 'chat.completion.chunk', choices: [], usage: completion.usage });
  return new Response(chunks.map(chunk => 'data: ' + JSON.stringify(chunk) + '\n\n').join('') + 'data: [DONE]\n\n', { headers: { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-store' } });
}
