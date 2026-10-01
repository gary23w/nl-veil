// neuron-db — the official host binding for the Rust core compiled to WASM.
//
// One dependency-free ES module that turns the raw `mem(ptr,len)` byte-FFI + tab protocol into a
// typed, self-validating API. The cortex (gary-neuron) is the centerpiece — ALWAYS mount a cortex
// build and let it dispatch; it is the cheap front gate that answers from memory and only escalates
// to a big model when memory can't. `route()` is the headline call:
//
//   import { NeuronDB } from "./neuron-db.mjs";
//   import wasmModule from "./neuron_core.wasm";          // Cloudflare CompiledWasm import (cortex baked in)
//   const db = NeuronDB.fromModule(wasmModule);           // (browser/node: await NeuronDB.fromBytes(bytes))
//   db.observeMany("session:42", priorFacts);
//   const turn = db.route("session:42", userMessage);     // recall + cortex dispatch, in one call
//   // turn = { type:"answer"|"escalate"|"fetch"|"store", value, facts } — act on type; raw model
//   //        text never reaches the user (a degenerate generation resolves to "escalate", not garbage).
//
// And the memory engine underneath, used directly when you want it:
//   const hits = db.recallScored("corpus", question, 8);  // [{fact, coverage, overlap}], best-first
//   const blob = db.dump("session:42");                   // persist; db.load("session:42", blob) restores
//
// It bakes in the things every embedder otherwise rediscovers the hard way:
//   • the alloc → write → mem → answer_ptr → dealloc memory dance, once,
//   • the per-op encode/decode/parse (recall lines, assess fields, scored tuples, dump/load blobs),
//   • the ROBUST retrieval default — `recall()` uses recall_many (the broad set `assess` counts),
//     never the single-best `recall` op that abstains on multi-word queries,
//   • a self-describing surface — it reads the build's `ops` at load and FAILS LOUD if you call an
//     op this build doesn't expose, instead of the silent empty string the raw FFI returns.
//
// Works in any WebAssembly host: Cloudflare Workers, the browser, Node, Deno, Bun.

const SENTINEL = String.fromCharCode(1); // mem() prefixes an unknown-op error with this; never appears in real output.

export class NeuronDB {
  /** Wrap an already-instantiated wasm `exports`. Prefer fromModule / fromBytes. */
  constructor(exports) {
    if (!exports || typeof exports.mem !== "function")
      throw new Error("neuron-db: these wasm exports have no mem() — not a neuron-db core build");
    this.ex = exports;
    this._td = new TextDecoder();
    this._te = new TextEncoder();
    if (typeof this.ex.mem_reset === "function") this.ex.mem_reset(); // fresh in-memory store
    // self-describe: which wire ops does THIS build actually expose? (empty set => skip validation)
    this.ops = new Set();
    const probe = this._raw("ops");
    if (probe && probe[0] !== SENTINEL) probe.split("\n").forEach((o) => o && this.ops.add(o));
    // cortex (the gary-neuron dispatcher) is a separate export, not a mem() op
    this.hasCortex = typeof this.ex.gary === "function" || typeof this.ex.run === "function";
  }

  /** From a WebAssembly.Module (Cloudflare's CompiledWasm import gives you one). Synchronous. */
  static fromModule(mod, imports = {}) {
    return new NeuronDB(new WebAssembly.Instance(mod, imports).exports);
  }
  /** From wasm bytes (browser fetch, Node fs.readFile). Async — compiles then instantiates. */
  static async fromBytes(bytes, imports = {}) {
    const { instance } = await WebAssembly.instantiate(bytes, imports);
    return new NeuronDB(instance.exports);
  }

  // ── low-level FFI (the dance, written once) ──────────────────────────────────
  _raw(...parts) {
    const e = this.ex;
    const bytes = this._te.encode(parts.join("\t"));
    const ptr = e.alloc(bytes.length);
    new Uint8Array(e.memory.buffer, ptr, bytes.length).set(bytes);
    const n = e.mem(ptr, bytes.length);
    const out = this._td.decode(new Uint8Array(e.memory.buffer, e.answer_ptr(), n));
    if (e.dealloc) e.dealloc(ptr, bytes.length);
    return out;
  }
  /** A checked call: validates the op against the build's surface and raises the fail-loud sentinel. */
  _call(op, ...args) {
    if (this.ops.size && !this.ops.has(op))
      throw new Error(`neuron-db: op "${op}" is not in this wasm build (has: ${[...this.ops].join(", ")})`);
    const out = this._raw(op, ...args);
    if (out && out[0] === SENTINEL) throw new Error("neuron-db: " + out.slice(1));
    return out;
  }
  // tab and newline are wire delimiters — strip them from any free-text field we pass in.
  _clean(s) { return String(s == null ? "" : s).replace(/[\t\r\n]+/g, " ").replace(/\s+/g, " ").trim(); }

  /** The wire ops this build exposes. */
  listOps() { return [...this.ops]; }
  /** Whether an op is present in this build. */
  supports(op) { return this.ops.size === 0 || this.ops.has(op); }
  /** Raw escape hatch for an op the typed API doesn't cover. Returns the raw tab/newline string. */
  raw(op, ...args) { return this._call(op, ...args); }

  // ── write ────────────────────────────────────────────────────────────────────
  /** Store one fact (the core may split it into sentence-level episodes). Returns episodes stored. */
  observe(scope, fact) { return parseInt(this._call("observe", scope, this._clean(fact)), 10) || 0; }
  /** Bulk-store many facts in one crossing. Returns episodes stored (≥ lines: a rich line fans out). */
  observeMany(scope, facts) {
    const lines = (facts || []).map((f) => this._clean(f)).filter(Boolean);
    return lines.length ? parseInt(this._call("obsmany", scope, lines.join("\n")), 10) || 0 : 0;
  }

  // ── read (recall defaults to the robust recall_many path, not the abstaining single-hit op) ──
  /** Top-k recalled facts for a query, best-first. The plug-and-play default for RAG + memory. */
  recall(scope, query, k = 6) { return this.recallScored(scope, query, k).map((r) => r.fact); }
  /** Recall with per-hit confidence: [{fact, coverage 0..1, overlap}], best-first. */
  recallScored(scope, query, k = 6) {
    const out = this._call("recallscored", scope, this._clean(query), String(k));
    if (!out) return [];
    return out.split("\n").filter(Boolean).map((line) => {
      const [fact, coverage, overlap] = line.split("\t");
      return { fact, coverage: parseFloat(coverage) || 0, overlap: parseInt(overlap, 10) || 0 };
    });
  }
  /** A single best-matching value for a direct question, or null. */
  recallValue(scope, query) { return this._call("value", scope, this._clean(query)) || null; }
  /** The knowledge-gap signal: how well memory covers a query (drive escalate/fetch decisions off this). */
  assess(scope, query) {
    const p = this._call("assess", scope, this._clean(query)).split("\t");
    return {
      coverage: parseFloat(p[0]) || 0, overlap: parseInt(p[1], 10) || 0, exact: parseInt(p[2], 10) || 0,
      hits: parseInt(p[3], 10) || 0, hasValue: p[4] === "1", topFact: p.slice(5).join("\t"),
    };
  }
  /** Spreading-activation recall: facts linked to the query through shared entities. */
  assoc(scope, query, k = 8, hops = 2) {
    const out = this._call("assoc", scope, this._clean(query), String(hops), String(k));
    return out ? out.split("\n").filter(Boolean) : [];
  }
  /** Walk a relation chain server-side: chain("o","Aurora",["owner","manager"]) -> {value, trail}. */
  chain(scope, start, path) {
    const out = this._call("chain", scope, this._clean(start), ...(path || []).map((p) => this._clean(p)));
    const [value, trail] = out.split("\t");
    return { value: value || null, trail: trail || "" };
  }

  // ── variables ────────────────────────────────────────────────────────────────
  setVar(scope, key, value) { this._call("setvar", scope, this._clean(key), this._clean(value)); return this; }
  getVar(scope, key) { return this._call("getvar", scope, this._clean(key)) || null; }
  vars(scope) {
    const out = this._call("vars", scope);
    const o = {};
    if (out) out.split("\n").forEach((l) => { const i = l.indexOf("\t"); if (i > 0) o[l.slice(0, i)] = l.slice(i + 1); });
    return o;
  }
  delVar(scope, key) { return this._call("delvar", scope, this._clean(key)) === "1"; }

  // ── lifecycle ────────────────────────────────────────────────────────────────
  /** Drop facts containing `match` (substring), or the whole scope if omitted. Returns count removed. */
  forget(scope, match) { return parseInt(this._call("forget", scope, match ? this._clean(match) : ""), 10) || 0; }
  /** Fact count held by a scope. */
  stats(scope) { return parseInt(this._call("stats", scope), 10) || 0; }
  /** Every live scope as [{scope, count}]. */
  scopes() {
    const out = this._call("scopes");
    return out ? out.split("\n").filter(Boolean).map((l) => { const [scope, c] = l.split("\t"); return { scope, count: parseInt(c, 10) || 0 }; }) : [];
  }
  /** Serialize a scope to a portable blob (persist this; restore with load). Survives a stateless request. */
  dump(scope) { return this._call("dump", scope); }
  /** Restore a scope from a dump blob (replaces it). The blob carries tabs — passed through verbatim. */
  load(scope, blob) { return parseInt(this._call("load", scope, blob), 10) || 0; }

  // ── capability manifest (§7) ──────────────────────────────────────────────────
  /** neuron's capability manifest: [{name, owner:"grounded"|"deferrable", about}]. */
  caps() {
    return this._call("caps").split("\n").filter(Boolean).map((l) => { const [name, owner, about] = l.split("\t"); return { name, owner, about }; });
  }
  /** Resolve keep/defer for a host advertising `hostCaps` (grounded caps always stay local). */
  resolveCaps(hostCaps = []) {
    return this._call("caps", ...hostCaps).split("\n").filter(Boolean).map((l) => { const [name, disposition] = l.split("\t"); return { name, disposition }; });
  }

  // ── cortex (only when the build bakes gary-neuron) ────────────────────────────
  /**
   * Route a turn through the gary-neuron dispatcher over a recalled working set. Returns a typed
   * decision the host acts on — NEVER raw model text, so a degenerate generation can't leak to the
   * user. { type: "answer"|"escalate"|"fetch"|"store", value }:
   *   answer   -> show value (memory answered it)
   *   escalate -> hand to the host LLM (memory can't; pass `facts` as context)
   *   fetch    -> a live-world lookup; value is the topic to search
   *   store    -> a declarative to remember; value is the canonical fact
   */
  dispatch(query, facts = []) {
    if (!this.hasCortex) throw new Error("neuron-db: this build has no cortex (gary) — dispatch unavailable");
    const fn = this.ex.gary || this.ex.run;
    const input = [this._clean(query), ...(facts || []).map((f) => this._clean(f))].join("\n");
    const bytes = this._te.encode(input);
    const ptr = this.ex.alloc(bytes.length);
    new Uint8Array(this.ex.memory.buffer, ptr, bytes.length).set(bytes);
    const n = fn(ptr, bytes.length);
    const raw = this._td.decode(new Uint8Array(this.ex.memory.buffer, this.ex.answer_ptr(), n)).trim();
    if (this.ex.dealloc) this.ex.dealloc(ptr, bytes.length);
    for (const t of ["answer", "fetch", "store"]) {
      const tag = t.toUpperCase() + " ";
      if (raw.startsWith(tag)) return { type: t, value: raw.slice(tag.length).trim() };
    }
    return { type: "escalate", value: "" }; // anything not a clean ANSWER/FETCH/STORE -> escalate (incl. degenerate output)
  }

  /**
   * The full cortex loop in one call — the headline primitive. Recall a working set from `scope`,
   * then route the turn through gary-neuron over it. Returns the typed decision plus the facts it
   * saw: { type:"answer"|"escalate"|"fetch"|"store", value, facts }. The host acts on `type`:
   *   answer   -> reply with value (no host-LLM call — the cheap path the cortex exists for)
   *   escalate -> call the host LLM, passing `facts` as grounding context
   *   fetch    -> do a live-world lookup for `value`
   *   store    -> remember `value` (often: observe it back into the scope)
   * The cortex is always the front gate, so raw model text never reaches the user.
   */
  route(scope, query, { k = 6 } = {}) {
    if (!this.hasCortex) throw new Error("neuron-db: this build has no cortex (gary) — mount a cortex build; the cortex is the dispatcher, never bypass it");
    const facts = this.recall(scope, query, k);
    return { ...this.dispatch(query, facts), facts };
  }
}

export default NeuronDB;
