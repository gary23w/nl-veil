import { DurableObject, WorkerEntrypoint } from 'cloudflare:workers';
import { routeGaryRequest, runGaryAI } from './gateway.mjs';
import bootstrapSource from './bootstrap.py';

const idleMs = 15 * 60 * 1000;

export class GaryBackend extends WorkerEntrypoint {
  fetch(request) { return routeGaryRequest(request, this.env); }
}

export class GaryAI extends WorkerEntrypoint {
  fetch(request) { return runGaryAI(request, this.env); }
}

export class GaryContainer extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    this.starting = null;
    this.checkpointing = null;
    this.inFlight = 0;
    this.lastUsed = Date.now();
  }

  control(path, body, size) {
    return this.ctx.container.getTcpPort(8791).fetch('http://gary-control' + path, {
      method: 'POST', headers: { Authorization: 'Bearer ' + this.env.GARY_RUNTIME_TOKEN, ...(size != null ? { 'Content-Length': String(size) } : {}) },
      ...(body ? { body } : {}), signal: AbortSignal.timeout(60000),
    });
  }

  runtimeEnvironment() {
    return {
      GARY_RUNTIME_TOKEN: this.env.GARY_RUNTIME_TOKEN,
      GARY_LLM_PROVIDER: 'openai', GARY_LLM_BASE_URL: 'http://gary.ai/v1',
      GARY_LLM_MODEL: this.env.GARY_LLM_MODEL || '@cf/zai-org/glm-4.7-flash',
      GARY_LLM_STREAM: 'false', OPENAI_API_KEY: 'cloudflare-private-binding',
      GARY_SKILL_REGISTRY: '/app/skills/registry.json',
      PLAYWRIGHT_BROWSERS_PATH: '/opt/browsers', NODE_PATH: '/usr/local/lib/node_modules',
      HOME: '/home/node', PATH: '/usr/local/go/bin:/usr/local/bin:/usr/bin:/bin',
    };
  }

  async launchRuntime() {
    const browser = await this.ctx.container.exec(['sh','-c','mkdir -p /opt/google/chrome && ln -sf /usr/bin/chromium /opt/google/chrome/chrome'], {stdout:'ignore',stderr:'ignore'});
    if (await browser.exitCode !== 0) throw new Error('Gary browser initialization failed.');
    const copied = await this.ctx.container.exec(['sh','-c','cat > /app/bootstrap.py'], {stdin:new Response(bootstrapSource).body, stdout:'ignore', stderr:'ignore'});
    if (await copied.exitCode !== 0) throw new Error('Gary bootstrap update failed.');
    await this.ctx.container.exec(['sh', '-c', 'exec python3 /app/bootstrap.py > /tmp/gary-bootstrap.log 2>&1'], {
      user: '1000:1000', env: this.runtimeEnvironment(), stdout: 'ignore', stderr: 'ignore',
    });
  }

  async installRuntime() {
    const hash = this.env.GARY_BUILD_ID;
    if (!/^[a-f0-9]{64}$/.test(hash || '')) throw new Error('Gary source package is not configured.');
    const source = await this.env.GARY_STATE.get('build/' + hash + '.tar.gz');
    if (!source || source.size > 32 * 1024 * 1024) throw new Error('Gary source package is missing or too large.');
    const bytes = await source.arrayBuffer();
    const digest = [...new Uint8Array(await crypto.subtle.digest('SHA-256', bytes))].map(v => v.toString(16).padStart(2, '0')).join('');
    if (digest !== hash) throw new Error('Gary source package checksum failed.');
    const unpack = await this.ctx.container.exec(['sh', '-c', 'rm -rf /app/source && mkdir -p /app/source && tar -xzf - -C /app/source'], {stdin: new Response(bytes).body, stdout:'ignore', stderr:'ignore'});
    if (await unpack.exitCode !== 0) throw new Error('Gary source unpack failed.');
    const install = await this.ctx.container.exec(['sh', '-c', 'pkill -TERM -f "^/usr/local/go/bin/go (test|build)" || true; pkill -TERM -f "^/usr/local/go/pkg/tool/linux_amd64/(compile|vet|link)" || true; timeout --kill-after=20s 1800 sh /app/source/install.sh > /tmp/gary-install.log 2>&1'], {stdout:'ignore', stderr:'ignore'});
    await this.ctx.storage.put('buildStatus', {phase:'building', pid:install.pid, hash, startedAt:Date.now()});
    if (await install.exitCode !== 0) {
      const log = await this.ctx.container.exec(['tail', '-c', '8000', '/tmp/gary-install.log']);
      throw new Error('Gary cloud build failed: ' + new TextDecoder().decode((await log.output()).stdout));
    }
    const snapshot = await this.ctx.container.snapshotContainer({name:'gary-' + hash.slice(0,16)});
    await this.ctx.storage.put('preparedRuntime', {hash, snapshot, createdAt:Date.now()});
    await this.launchRuntime();
    await this.bootRuntime();
    await this.ctx.storage.put('buildStatus', {phase:'ready', hash, completedAt:Date.now()});
  }

  async bootRuntime() {
    let ready = false;
    for (let i = 0; i < 60; i++) {
      try { const status = await this.control('/status'); if (status.ok) { ready = (await status.json()).running; break; } } catch {}
      await new Promise(resolve => setTimeout(resolve, 500));
    }
    if (!ready) {
      const state = await this.env.GARY_STATE.get('runtime/state.tar.gz');
      const boot = await this.control('/boot', state?.body, state?.size);
      if (!boot.ok) throw new Error('Gary Container could not initialize its local database and runtime: ' + (await boot.text()).slice(0,2000));
    }
  }

  beginInstall() {
    this.starting = this.installRuntime().catch(async error => {
      await this.ctx.storage.put('buildStatus', {phase:'failed', hash:this.env.GARY_BUILD_ID, error:error.message.slice(0,8000)});
      console.error(error.message);
    }).finally(() => { this.starting = null; });
    this.ctx.waitUntil(this.starting);
    throw new Error('Gary is building its dedicated Cloudflare runtime. Retry shortly.');
  }

  async ensureRunning() {
    if (this.starting) throw new Error('Gary is building its dedicated Cloudflare runtime. Retry shortly.');
    const container = this.ctx.container;
    if (!container) throw new Error('Gary Container is not configured.');
    const installed = await this.ctx.storage.get('buildStatus');
    if (container.running && installed?.phase === 'ready' && installed.hash !== this.env.GARY_BUILD_ID) {
      const saved = await this.checkpoint();
      if (!saved.checkpointed) throw new Error(saved.error || 'Gary source update is waiting for active tasks to finish.');
    }
    if (!container.running) {
      const prepared = await this.ctx.storage.get('preparedRuntime');
      const available = prepared && Date.now() - prepared.createdAt < 29 * 86400000;
      const reusable = available && prepared.hash === this.env.GARY_BUILD_ID;
      container.start({ ...(available ? {containerSnapshot:prepared.snapshot} : {image:'cloudflare/debian-trixie'}), instance:'standard-1', entrypoint:['sleep','infinity'], enableInternet:true });
      await container.setInactivityTimeout(60 * 60 * 1000);
      await container.interceptOutboundHttp('gary.ai', this.ctx.exports.GaryAI({}));
      if (reusable) await this.launchRuntime();
      else {
        this.beginInstall();
      }
    }
    await container.setInactivityTimeout(60 * 60 * 1000);
    await container.interceptOutboundHttp('gary.ai', this.ctx.exports.GaryAI({}));
    const status = await this.ctx.storage.get('buildStatus');
    if (!status) this.beginInstall();
    if (status?.phase === 'failed') {
      const retried = await this.ctx.storage.get('buildRetryCount') || 0;
      if (!retried && status.error?.startsWith('Gary cloud build failed:')) {
        await this.ctx.storage.put('buildRetryCount', 1);
        this.beginInstall();
        throw new Error('Gary is retrying its Cloudflare runtime build. Retry shortly.');
      }
      const prepared = await this.ctx.storage.get('preparedRuntime');
      if (prepared?.hash !== this.env.GARY_BUILD_ID) throw new Error(status.error);
      await this.launchRuntime();
      await this.bootRuntime();
      await this.ctx.storage.put('buildStatus', {phase:'ready', hash:this.env.GARY_BUILD_ID, completedAt:Date.now()});
    }
    if (status?.phase === 'building') throw new Error('Gary is building its dedicated Cloudflare runtime. Retry shortly.');
    await this.bootRuntime();
  }

  async fetch(request) {
    if (request.headers.get('Authorization') !== 'Bearer ' + this.env.GARY_RUNTIME_TOKEN) return new Response('Unauthorized', { status: 401 });
    this.inFlight++;
    this.lastUsed = Date.now();
    try {
      if (this.checkpointing) await this.checkpointing;
      if (new URL(request.url).pathname === '/runtime/status') {
        const status = await this.ctx.storage.get('buildStatus') || {phase:'not-started'};
        if (this.ctx.container.running) {
          const process = await this.ctx.container.exec(['sh','-c','tail -c 100 /tmp/gary-install.log; test ! -f /tmp/gary-bootstrap.log || tail -c 4000 /tmp/gary-bootstrap.log; grep -n ControlServer /app/bootstrap.py; ps -eo pid,comm | tail -n 12']);
          status.progress = new TextDecoder().decode((await process.output()).stdout);
        }
        return Response.json({ok:true, bootstrapVersion:'hostname-bind-v1', ...status});
      }
      await this.ensureRunning();
      if (new URL(request.url).pathname === '/runtime/checkpoint') {
        this.checkpointing = this.checkpoint();
        try { return Response.json(await this.checkpointing); } finally { this.checkpointing = null; }
      }
      const response = await this.ctx.container.getTcpPort(8790).fetch(request);
      const result = await response.arrayBuffer();
      if (result.byteLength > 4 * 1024 * 1024) throw new Error('Gary result exceeds 4 MiB.');
      return new Response(result, { status: response.status, headers: response.headers });
    } catch (error) { return Response.json({ ok: false, error: error.message }, { status: 503 }); }
    finally { this.inFlight--; this.lastUsed = Date.now(); await this.ctx.storage.setAlarm(this.lastUsed + idleMs); }
  }

  async alarm() {
    if (this.inFlight || Date.now() - this.lastUsed < idleMs) {
      await this.ctx.storage.setAlarm(Date.now() + idleMs); return;
    }
    if (!this.ctx.container.running) return;
    this.checkpointing = this.checkpoint();
    try { await this.checkpointing; } finally { this.checkpointing = null; }
  }

  async checkpoint() {
    try {
      const busy = await this.control('/busy');
      if (!busy.ok || (await busy.json()).busy) { await this.ctx.storage.setAlarm(Date.now() + idleMs); return {ok:true,checkpointed:false,reason:'Runtime is busy.'}; }
      const backup = await this.control('/checkpoint');
      if (!backup.ok) throw new Error('Gary checkpoint failed; container retained.');
      const size = Number(backup.headers.get('Content-Length'));
      if (!Number.isSafeInteger(size) || size <= 0 || size > 256 * 1024 * 1024) throw new Error('Invalid Gary checkpoint length.');
      const stream = new FixedLengthStream(size);
      const controller = new AbortController();
      const copied = backup.body.pipeTo(stream.writable, { signal: controller.signal });
      try {
        await Promise.all([copied, this.env.GARY_STATE.put('runtime/state.tar.gz', stream.readable, { httpMetadata: { contentType: 'application/gzip' } })]);
      } catch (error) {
        controller.abort();
        await copied.catch(() => {});
        throw error;
      }
      await this.ctx.container.destroy();
      return {ok:true,checkpointed:true};
    } catch (error) {
      console.error('Gary persistence failed:', error.message);
      await this.control('/boot').catch(() => {});
      await this.ctx.storage.setAlarm(Date.now() + idleMs);
      return {ok:false,checkpointed:false,error:error.message};
    }
  }
}

export default { fetch() { return new Response('Not found', { status: 404 }); } };
