# Swarm Micro-VCS for nl-veil — Optimistic Anchor-Rebase (FINAL, hardened)

**Status:** implementation-ready. Spine = Approach 1 (optimistic anchor-rebase). All critic findings from the three adversarial lenses (corruption/atomicity C1–C9, concurrency/races F1–F9, merge-correctness/weak-model-UX MF1–MF9) are folded in explicitly; §8 maps each to its fix. Where a concern is not real given the substrate, §8.4 says why and moves on.

**Target repo:** the nl-veil / neuron-loops Zig worker (`src/worker/{tools,bufedit,run}.zig`). Authored against the authoritative substrate map; the Zig sources are not in *this* (`neuron-db` Rust) checkout, per project memory. New files: `src/worker/vcs.zig`, plus one small, explicit `bufedit.Applied` extension (§3.1, first-class in v1). Call sites touched: `writeFile` [tools.zig:720] and `editFile` [tools.zig:786], routed through `vcs.commit` after their existing parse/`safeRel`, reusing the `w.files_mtx` the manifest already takes.

---

## 1. Summary + core insight

`bufedit.apply` already **is** a content-anchored 3-way merge engine: it locates edits by content anchor, not line number (map: bufedit KEY PROPERTY). Re-running a mind's ops against **fresh HEAD read inside the lock** auto-merges disjoint edits and returns a clean, mutation-free reject when two minds touch the same region — a full 3-way merge with no diff3, no line-ID CRDT, no stored per-line metadata (the anchor *is* the stable line identity). The VCS adds only: (a) a durable per-file content-addressed HEAD to rebase against; (b) a serialized commit under the existing `w.files_mtx` that reads HEAD *inside* the lock (kills the TOCTOU lost update); (c) a bounded conflict-resolution ladder so a weak 20B cannot livelock.

**The single load-bearing correction from the critics:** the design's atomicity story is airtight only for the object-store-and-ref under a *process kill with a warm page cache*. Three seams cracked, and this revision closes all three:

1. **Intent-first journaling.** A `pending` intent record is fsync'd *before* any `work/` mutation, so crash recovery can distinguish a validated-merge-that-crashed-before-the-ref-flip from raw bytes that were about to be *rejected*. Recovery never blindly trusts disk (fixes C2, C7, C8-recovery).
2. **Disk is authoritative in `--embed`.** HEAD content is read from the on-disk work-file (verified `hash(disk) == ref.head`) *inside the lock*, not from the object cache, so an external `git checkout` / editor save is detected as a conflict instead of silently clobbered (fixes C5, C4-divergence, MF5, F6).
3. **Identity-verified anchoring + pinned syscalls.** The rebase guard verifies the *base-side line identity* of each anchor survived, not just a byte offset; every disk landing is pinned to a true atomic rename (`ReplaceFileW` / `MoveFileExW(...WRITE_THROUGH)`), fsync-ordered object-before-ref, never a byte-copy fallback (fixes C1, C3, C6, MF1, MF3, MF6).

Silent-wrong merges have **no code path**: the only writer of bytes into `work/` is a successful `bufedit.apply` (unique, identity-verified anchors) or an exclusive whole-buffer replace that itself passes that same check. The worst outcome is a *rejected* commit, never a *wrong* one.

---

## 2. On-disk layout under `run_dir`

The VCS store is a **sidecar**, never inside `work/` (which may be a junction to the real user tree / a live git repo). All VCS state lives beside the existing `.build_manifest`, always on the same volume as `run_dir`.

```
<run_dir>/
  work/                          # UNCHANGED deliverable tree (possibly a junction into a live repo).
  .build_manifest                # UNCHANGED "path|len\n" log, guarded by files_mtx.
  .vcs/                          # NEW. All micro-VCS state. Never a junction; always run_dir-local.
    intent/
      <refKey>.intent            # single-slot pending-commit journal (fsync'd BEFORE work/ write)
    objects/
      tmp/                       #   O_EXCL staging for temp+rename of objects (crypto-random names)
      ab/ab3f…9c                 #   whole-file snapshot (raw bytes; dedup-by-content)
    refs/
      <refKey>.head              # per-file HEAD ref, 32-hex filename stem; temp+rename rewritten
    log/
      <refKey>.log               # append-only per-file commit journal (advisory / observability)
    conflicts/
      <refKey>.<round>.rej       # conflict record fed to a resolver mind (ladder rung 2)
    index.tsv                    # debug-only: npath \t refKey \t seq  (NOT authoritative)
```

`base/` from earlier drafts is **removed** as a separate directory: round-start snapshots are just objects the GC pins, so a round-start snapshot equal to a prior commit's bytes is literally the *same* blob (free dedup), with no second namespace to keep coherent.

**Filename stem = `refKey`.** Promoted from `fnv1a64` to a **128-bit xxh3-128 of `npath`**, rendered 32 hex, so path-hash collisions are negligible at swarm scale (fixes C9). The full `npath` is still stored inside the ref/log/intent line; on the astronomically-improbable stem collision the stored `npath` mismatches and we do **not** downgrade to an untracked plain write — we chain (§4.5) and log loudly. `npath` = the `safeRel`-normalized relative path (map: safeRel [tools.zig:2793]).

**Ref file format** (`refs/<refKey>.head`), single line, atomic temp+rename:
```
<head_hash:32hex> <seq:decimal> <npath>\n
```
`seq` is the monotone per-file version; it advances on every commit and is the source of truth for "did the world change" (§4.3, fixes F5 ABA).

**Intent file format** (`intent/<refKey>.intent`), single-slot, fsync'd, overwritten each commit:
```
<seq_target:decimal>\t<parent_hash:32hex>\t<target_hash:32hex>\t<mind_id>\t<epoch_ms>\t<npath>\n
```
Written and flushed *before* the `work/` mutation; deleted (or overwritten by the next commit) only *after* the ref rename lands. Its presence at startup means "a commit was in flight"; recovery consults it (§4.4).

**Log line format** (`log/<refKey>.log`), append-only, tab-separated, one commit per line (torn tail line is obvious-invalid and dropped; correctness never reads the log back):
```
<seq>\t<hash>\t<parent_hash>\t<mind_id>\t<epoch_ms>\t<kind>\t<status>\t<npath>\n
```
`kind` ∈ `init | edit | write | merge`. `status` ∈ `applied | rebased | merged | conflict | resolved | recovered | superseded`.

**Objects** are whole-file snapshots keyed by the xxh3-128 of the exact committed bytes. Written `objects/tmp/<crypto-rand>` (O_EXCL) → the buffer is **re-hashed after the write and asserted == expected**, its length asserted == expected → fsync'd → renamed to `objects/<xx>/<hash>` → the `objects/<xx>/` dir is fsync'd (fixes C3, C6, C7). Name = content hash, so a torn/short-written temp is never referenced and is GC-able.

**Hash choice:** **xxh3-128** (32 hex), pure Zig, no crypto dep, collision-safe for run-scoped ephemeral stores where content is not adversarially chosen. Same primitive for object hash and `refKey`. Not blake3 — hashing full bytes with blake3 in-lock on every commit including `--quick` was a flagged large-file regression. Swappable behind `const Hash = [16]u8` if a future threat model needs collision resistance.

---

## 3. Data structures (Zig)

```zig
// src/worker/vcs.zig — pure, in-process, no external deps beyond std + bufedit.

const Hash   = [16]u8;               // xxh3-128 of committed bytes (32 hex chars)
const RefKey = [16]u8;               // xxh3-128(npath) — sidecar filename stem (128-bit; C9)

fn hexHash(h: [16]u8) [32]u8 { … }   // lowercase hex
fn refKey(npath: []const u8) RefKey { … } // xxh3-128

// ---- the per-file HEAD ref (parsed from refs/<refKey>.head) -----------------
const Ref = struct {
    head: Hash,
    seq: u32,                // monotone per file; 0 = untracked/first. SOURCE OF TRUTH for "changed".
    npath: []const u8,       // authoritative path stored in-ref (collision guard)
};

const CommitKind = enum { init, edit, write, merge };

// ---- per-op anchor identity captured at op-build time (fixes MF1/MF3/MF6) ----
// For BOTH explicit edit_file ops AND parseNarrated SEARCH/REPLACE prose, we resolve each
// anchor against the mind's OWN base bytes at build time (outside the lock) and capture:
//   base_offset : byte offset of the anchor's match in base (defined even for narrated ops,
//                 which carry no model-supplied `at`)
//   ctx_before / ctx_after : the one physical line immediately above/below the matched anchor
//                 in base — the anchor's LINE IDENTITY, used by the rebase guard to prove the
//                 surviving HEAD match is the SAME logical line, not merely A unique line.
const AnchoredOp = struct {
    op: bufedit.EditOp,      // kind, anchor, text (anchor already min-unique-expanded — §4.1)
    base_offset: u64,        // resolved locus in base bytes (NOT a model-supplied line number)
    ctx_before: []const u8,  // line above anchor in base ("" if top of file)
    ctx_after: []const u8,   // line below anchor in base ("" if EOF)
    span_lines: u32,         // #lines this op's anchor spans (sizes the conflict neighbourhood — MF7)
};

// ---- what a mind's write/edit call carries into the commit path -------------
// Ops are ALWAYS []AnchoredOp — write_file is LOWERED to a whole-buffer replace op BEFORE the
// lock, so the critical section has ONE input shape.
const Change = struct {
    npath: []const u8,
    base: ?Hash,             // HEAD hash the mind THINKS it derived from; null = new/no-read
    base_seq: ?u32,          // seq observed at read time (drives `rebased`, NOT hash — F5)
    ops: []AnchoredOp,
    is_full_write: bool,     // origin was write_file
    full_bytes: ?[]const u8, // present iff is_full_write (new-file + full-conflict re-prompt)
    mind_id: u32,
    round: u32,
    retry: u8,               // ladder rung counter (0 = first attempt); §5.1
    embed: bool,             // work/ is a junction into a live external tree (disk authoritative — C5)
};

const CommitOutcome = union(enum) {
    committed: struct { new_head: Hash, seq: u32, rebased: bool, kind: CommitKind, bytes_len: usize },
    conflict:  struct {
        reason: []const u8,
        current_head: Hash,
        reject: []const u8,        // bufedit vocabulary: anchor-not-found | anchor-ambiguous | anchor-drift
        neighbourhood: []const u8, // sized to the edit span (MF7), for the re-anchor prompt
        full_diff: ?[]const u8,    // present when is_full_write: base→HEAD diff for the re-write prompt (MF4)
        charge_retry: bool,        // false when the conflict was pure HEAD-advance churn (F2)
    },
    noop:      struct { reason: []const u8 },
};

// ---- the VCS handle, one per worker ----------------------------------------
const Vcs = struct {
    dir: []const u8,          // "<run_dir>/.vcs"
    fmtx: *std.Io.Mutex,      // &w.files_mtx — THE SAME lock the manifest uses
    io: std.Io,
    gpa: std.mem.Allocator,
    enabled: bool,            // false on --quick single-mind (§7)
    embed: bool,              // set once at run start from run config
    lock_epoch: std.atomic.Value(u64) = .{ .raw = 0 }, // monotone tick bumped on each lock acquire;
                              // GC never unlinks an object touched by a commit at/after its snapshot (C8/F3)
    // NO last_seen map (deleted — F1/F8: it only phrased a message that ref.head already provides).
    // NO in-RAM HEAD cache: HEAD is always read from disk INSIDE the lock (constraint 7).
    // NO leases in v1 (F8): claim_region is Phase 3 pure-steering; if added it is fmtx-guarded.
};
```

`Change.ops` is unconditionally `[]AnchoredOp` — the merge engine has one input shape; `write_file` and `edit_file` converge *before* the lock.

### 3.1 The one first-class `bufedit` extension (v1, not deferred)

Every silent-wrong defense rides on knowing *where each op matched*. `bufedit.apply` today rejects on ambiguity and splices highest-offset-first internally but does not surface the per-op locus. v1 adds:

```zig
const MatchLocus = struct { op_index: u32, matched_offset: u64 };
// bufedit.Applied gains: loci: []MatchLocus   (one per applied op, resolved AFTER internal splicing)
```

This is a small, contained change plumbed through the all-or-nothing splice, with its own bufedit unit test (locus correct under prior splices). It is **gated into v1** because the drift/identity guard (§4.3, §5) cannot exist without it. Nothing else in bufedit changes.

---

## 4. Write/commit + merge/rebase algorithm

### 4.1 Both entry points build a common `Change` (outside the lock)

**`editFile` path** (map: editFile [tools.zig:786] reads original via `readFileAlloc` [tools.zig:803] outside any lock, calls `bufedit.apply`):
1. Read `base_bytes` = current work-file bytes; `base = hash(base_bytes)`. Same outside-lock read as today. Capture `base_seq = readRef(npath).seq` (a cheap disk read; no lock — advisory here, re-validated in-lock).
2. Parse ops from `{path, ops}` **or** `bufedit.parseNarrated` for SEARCH/REPLACE prose.
3. **Anchor min-unique expansion (fixes MF2).** For *every* op — no `< 24 byte` length gate — resolve the anchor in `base_bytes` and, if it is not already unique, expand it by whole lines of surrounding context until it is unique *in base* (bounded expansion; if it cannot be made unique because base itself has ≥2 identical regions, mark the op `ambiguous_in_base` so the commit path treats it as a conflict candidate rather than guessing). Cheap; a few bytes per op; converts would-be post-rebase conflicts into clean auto-merges and stops handing long "seemingly-safe" anchors zero protection.
4. **Capture per-op identity (fixes MF1/MF3/MF6).** For each op record `base_offset` (its resolved match locus in `base_bytes`) and `ctx_before` / `ctx_after` (the physical lines bracketing the anchor in base) and `span_lines`. `base_offset` is well-defined for narrated ops that carry no `at`.
5. Build `Change{ ops=[]AnchoredOp, base, base_seq, is_full_write=false, embed }`.

**`writeFile` path** (map: writeFile [tools.zig:720] plain whole-file write) — lowered so it can rebase:
1. File exists → read `base_bytes`, `base = hash`, `base_seq = ref.seq`; else `base=null`, `base_seq=null`.
2. `base == null` → genuine create: `Change{ ops=&.{}, is_full_write=true, full_bytes=content }`.
3. `base != null` → lower to one whole-buffer replace op:
   `AnchoredOp{ op=.{ .kind=.replace, .anchor=base_bytes, .text=content }, base_offset=0, ctx_before="", ctx_after="", span_lines=lineCount(base) }`, `is_full_write=true`, `full_bytes=content`.
   Any concurrent change makes the whole-buffer anchor vanish ⇒ `anchor-not-found` ⇒ conflict, never a silent clobber (map: full-write LIMITATION). Coarse; the full-file conflict path (§5.2) re-prompts with a base→HEAD diff so the rewrite is *recoverable*, not dropped (fixes MF4). Fine per-hunk diff is Phase 3.

### 4.2 `commit(change) CommitOutcome` — the serialized critical section

Lock discipline (fixes F7): **acquire cancelable**, then make the mutation phase uncancelable so a queued fiber can still be reclaimed by the watchdog while a holder is wedged, but a holder mid-mutation is never cancelled leaving HEAD half-updated. No `panic` under the lock — every I/O error returns cleanly (a panic would poison the mutex for the whole worker).

```
commit(change):
  # --- outside the lock: all of §4.1 prep; NOTHING reads authoritative HEAD here ---

  fmtx.lock(io)                                  # cancelable acquire (F7)
  defer fmtx.unlock(io)
  epoch = vcs.lock_epoch.fetchAdd(1) + 1         # this commit's tick; GC pins >= snapshot (C8/F3)
  uncancelable_begin(io)                         # mutation phase only (F7)
  defer uncancelable_end(io)
  # === CRITICAL SECTION: serialized per WORKER (single global files_mtx — §8.4 gap) ===

  ref = readRef(change.npath)                    # HEAD FROM DISK, in-lock => no TOCTOU (constraint 7)

  # ---------- EMBED: disk is authoritative (fixes C5/C4/MF5/F6) ----------
  # If work/ is a live external tree, the object cache is only a cache. Verify it still equals
  # the real file; if an external process (git checkout, editor save) changed disk, re-adopt.
  if change.embed and ref != null:
      disk = readWorkFileOrNull(change.npath)
      if disk == null or hash(disk) != ref.head:
          # external write since our last commit — adopt disk as a fresh base, force rebase onto it
          ref = adoptAsHead(change.npath, disk, kind=.recovered)   # writes object+ref in-lock
          # change.base now differs from ref.head => `rebased` below is true; guard runs

  # ---------- Case NEW FILE (ref == null) ----------
  if ref == null:
      # FIRST-TOUCH ADOPTION (canonical untracked-file path). In embed mode, snapshot-guard the
      # read against a concurrent external writer (fixes MF5): stat size+mtime, read, re-stat;
      # on mismatch re-read once; if still unstable, return conflict("file is being written externally").
      disk = readWorkFileSnapshot(change.npath)
      if disk != null:
          initCommit(change.npath, disk.bytes, kind=.init, seq=0)  # seed HEAD from on-disk truth
          ref = readRef(change.npath)                              # now non-null -> fall through
      else:
          if change.is_full_write:  bytes = change.full_bytes
          else:
              applied = bufedit.apply(gpa, "", ops(change))        # insert-only vs ""; replace/delete reject
              if !applied.ok: return conflict(applied.reject, ZERO, "", null, charge=false)
              bytes = applied.bytes
          return writeCommit(change, parent=ZERO, bytes, kind=.write, seq=1, rebased=false, epoch)

  # ---------- Case EXISTING FILE ----------
  # Authoritative current content: in embed mode this IS the disk file we just verified == ref.head;
  # otherwise the object cache (equal by construction, cheaper).
  head_bytes = if change.embed then diskOrObject(ref.head) else readObject(ref.head)
  rebased    = (change.base_seq == null) or (change.base_seq.? != ref.seq)   # SEQ, not hash (F5)

  # any op that could not be made unique in base is a conflict candidate up front
  if anyAmbiguousInBase(change.ops):
      return conflict("ambiguous anchor (repeats in your base)", ref.head, "anchor-ambiguous",
                      neighbourhood(head_bytes, change.ops), fullDiffIfWrite(change, head_bytes),
                      charge=true)

  # THE REBASE: apply the mind's ops onto CURRENT HEAD. Returns per-op loci (§3.1).
  applied = bufedit.apply(gpa, head_bytes, ops(change))

  if !applied.ok:
      if applied.reject == "no-change": return noop("no-change")
      # F2: if the ONLY reason apply failed is that HEAD advanced (rebased) but this op's anchor
      # region was NOT itself rewritten, this is churn from a DISJOINT mover — do not charge a
      # retry; the ladder re-reads and the disjoint case fast-merges next attempt.
      churn = rebased and not anyAnchorRegionRewritten(change.ops, head_bytes)
      return conflict{ reason=classify(applied.reject), current_head=ref.head, reject=applied.reject,
                       neighbourhood=neighbourhood(head_bytes, change.ops),   # sized to span (MF7)
                       full_diff=fullDiffIfWrite(change, head_bytes),         # MF4
                       charge_retry = not churn }                             # F2

  # ---- IDENTITY-VERIFIED REBASE GUARD (fixes MF1/MF3/MF6, supersedes offset-only guard) ----
  # For each applied op, verify the LINE IDENTITY survived: the lines bracketing the match on HEAD
  # (at applied.loci[i].matched_offset) must still be compatible with the op's captured
  # ctx_before/ctx_after from base. A unique-but-wrong match (created by a teammate's delete of the
  # real target, or duplication elsewhere) has DIFFERENT surrounding lines => refused as conflict.
  # This replaces the pure |matched - original| window, which self-widened exactly when it mattered.
  if rebased and not identityPreserved(applied.loci, change.ops, head_bytes):
      return conflict{ reason="the line you targeted changed shape or moved; re-read and re-anchor",
                       current_head=ref.head, reject="anchor-drift",
                       neighbourhood=neighbourhood(head_bytes, change.ops),
                       full_diff=fullDiffIfWrite(change, head_bytes), charge_retry=true }

  new_bytes = applied.bytes
  if hash(new_bytes) == ref.head: return noop("no-effective-change")

  kind = if change.is_full_write then .write else if rebased then .merge else .edit
  return writeCommit(change, parent=ref.head, new_bytes, kind, seq=ref.seq+1, rebased, epoch)
```

### 4.3 `writeCommit` — intent-first, fsync-ordered, work-last, ref-is-linearization (fixes C1/C2/C3/C4/C7)

```
writeCommit(change, parent, bytes, kind, seq, rebased, epoch):
  h = hash(bytes)

  # 1. OBJECT FIRST, durably (so HEAD can never reference bytes that aren't on disk — C3/C6/C7).
  writeObjectDurable(h, bytes)          # O_EXCL tmp; re-hash==h & len check; fsync tmp; rename; fsync dir.
                                        # On ENOSPC/short-write: discard tmp (errdefer unlink), return
                                        # conflict("out of disk space") — WORK/ NOT YET TOUCHED.

  # 2. INTENT, durably, BEFORE any work/ mutation (fixes C2 — recovery validates against this).
  writeIntentDurable(refKey, seq, parent, target=h, change.mind_id, change.npath)  # fsync file+dir.

  # 3. WORK-FILE, atomically. HEAD/ref advance ONLY if this succeeds (fixes C4).
  ok = writeWorkFileAtomic(change.npath, bytes)   # pinned rename; NEVER byte-copies (C1). See §4.6.
  if !ok:                               # external open handle / sharing violation / rename error
      clearIntent(refKey)               # nothing landed on disk; roll intent back
      return conflict{ reason="the file is locked by another process; will retry", ...,
                       reject="work-locked", charge_retry=false }   # bounded retry OUTSIDE the lock

  # 4. REF — the LINEARIZATION POINT (temp+rename, last durable step).
  appendLog(refKey, seq, h, parent, change.mind_id, kind, statusFor(kind, rebased))
  writeRefAtomic(refKey, h, seq, change.npath)     # temp+rename; fsync refs/ dir.

  # 5. Intent satisfied; drop it (or leave it — the next commit overwrites; recovery ignores a
  #    pending intent whose target == current ref.head).
  clearIntent(refKey)

  appendManifest(change.npath, bytes.len)          # same files_mtx already held
  return committed{ new_head=h, seq, rebased, kind, bytes.len }
```

Ordering rationale: **object durable → intent durable → work file → ref**. Object-before-ref gives the C3 happens-before edge (a durable ref never points at non-durable bytes). Intent-before-work gives the C2 edge (recovery can tell a validated in-flight commit from suspect disk bytes). Ref-last is the linearization point (crash before it ⇒ old HEAD valid; crash after ⇒ consistent new HEAD whose bytes and intent already exist). Work-before-ref keeps the deliverable ahead of the ref so the reconcile in §4.4 has something to validate, but **the ref only advances after the work write returns success**, closing the HEAD-vs-disk divergence (C4).

### 4.4 Crash recovery (startup reconcile) — validates intent, never blind-trusts disk (fixes C2/C7/C8-recovery)

For each `refKey` with a `.intent` file present at startup, or where `hash(work/npath) != ref.head`:

```
recover(refKey):
  intent = readIntentOrNull(refKey)
  ref    = readRefOrNull(refKey)
  disk   = readWorkFileOrNull(npath)

  if ref != null and disk != null and hash(disk) == ref.head:
      clearIntent(refKey); return                       # clean; commit finished or never started

  if intent != null and disk != null and hash(disk) == intent.target
                    and objectExists(intent.target)
                    and intent.parent == (ref?.head orelse ZERO):
      # a VALIDATED merge crashed AFTER work-write, BEFORE ref-flip. Finish it forward.
      writeRefAtomic(refKey, intent.target, intent.seq, npath)
      appendLog(refKey, intent.seq, intent.target, intent.parent, intent.mind, .merge, .recovered)
      clearIntent(refKey); return

  # No matching intent => the disk bytes are SUSPECT (raw/unvalidated/torn). Restore last good HEAD.
  if ref != null and objectExists(ref.head):
      writeWorkFileAtomic(npath, readObject(ref.head)); clearIntent(refKey); return   # roll BACK, not forward

  # No ref at all (fresh) => first-touch adopt disk on next commit.
  clearIntent(refKey)
```

The key correction over the old "trust newer disk bytes" rule: adopting disk-as-HEAD happens **only** when a matching `pending` intent proves those bytes are the validated target of a commit that had already passed the apply + identity guard. Otherwise recovery **rolls back** to the last good HEAD and the write re-conflicts cleanly next round. A crash can no longer promote a would-be-rejected write to canonical.

### 4.5 `refKey` collision handling — chain, never downgrade (fixes C9)

With 128-bit `refKey`, a stem collision is astronomically improbable. If the stored `npath` in `refs/<stem>.head` nonetheless mismatches the committing `npath`, we do **not** fall back to an untracked plain write (which would reintroduce the very lost-update this VCS exists to kill). Instead the ref slot holds a short `npath → {head,seq}` association list; a mismatched stem probes the chain for its own `npath`, appends a new entry if absent, and logs `WARN refKey collision`. All writes stay VCS-tracked and go through `writeWorkFileAtomic`.

### 4.6 `writeWorkFileAtomic` — pinned atomic rename, never a byte-copy (fixes C1)

```
writeWorkFileAtomic(npath, bytes) -> bool:
  # temp BESIDE the target, guaranteed same volume (work/ is one mount even if a junction).
  tmp = work/.<basename>.<crypto-rand>.tmp
  errdefer unlink(tmp)                    # no litter in the user's tree on failure (C7)
  writeAllChecked(tmp, bytes)             # verify byte count; ENOSPC => return false, tmp unlinked
  fsyncFile(tmp)
  # Pin the primitive — NEVER std.fs.rename's EXDEV copy+unlink degrade:
  windows: ReplaceFileW(target, tmp, ... ) if target exists (atomic, preserves ACLs),
           else MoveFileExW(tmp, target, MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH).
  posix:   renameat2/rename on the SAME volume (asserted; refuse --embed if work/ tmp would cross mounts).
  on ERROR_SHARING_VIOLATION / EXDEV / any rename error:
      unlink(tmp); return false           # caller aborts the ref advance; NEVER a plain in-place write
  fsyncDir(dirOf(target))
  return true
```

Assert (in a unit test) that the fallback path never byte-copies. On `--embed`, at run start, refuse if `work/` and its temp would land on different volumes, and warn if external handles are detected on target files.

---

## 5. Conflict detection and resolution — silent wrong merge is refused, not risked

A merge commits **only** when `bufedit.apply(gpa, current_head, ops).ok` *and* the identity-verified rebase guard passes *and* the work write succeeded. Every wrong-merge path is closed:

1. **Lost update** (core race): eliminated — HEAD read *inside* the lock (from disk in embed mode), ops re-apply to *that* HEAD via `seq`-derived rebase. Second committer rebases onto the first.
2. **Overlapping same-region edits:** `anchor-not-found` (text changed) or `anchor-ambiguous` (map: never silently picks one) ⇒ conflict.
3. **Unique-but-wrong match** (teammate deleted the real target, or duplicated the anchor elsewhere): the **identity guard** (§4.3) sees the surviving match's bracketing lines differ from the op's captured `ctx_before/ctx_after` ⇒ `anchor-drift` conflict. This is the MF1 seam; it is *refused*, not risked. The old offset-only window (which widened exactly when a large concurrent delete made a distant wrong match likely) is gone.
4. **Full-file clobber:** whole-buffer anchor vanishes if HEAD ≠ base ⇒ conflict; recoverable via the diff re-prompt (§5.2), not dropped.
5. **No-op / self-cancel:** `hash(new)==head` or bufedit `no-change` ⇒ `noop`; HEAD unchanged.
6. **ABA** (content reverts to a prior hash while history advanced): `rebased` is derived from `seq`, not hash, so the guard still runs and the log stays linear (fixes F5).
7. **External write in `--embed`:** disk verified against `ref.head` in-lock; a mismatch re-adopts disk as base and forces rebase, never clobbers the user's `git checkout`/save (fixes C5).

**No conflict marker is ever written into `work/`.** The disk file is always a clean, fully-applied single committed state; the conflict lives in the tool result to the model.

### 5.1 Bounded resolution ladder (fixes F2 churn-charging, MF7 window sizing)

No rung can corrupt (bytes reach `work/` only via a successful, identity-guarded `apply` under the lock, work-write-before-ref-advance):

1. **Rung 0 — Auto-rebase.** `apply` succeeds on live HEAD (disjoint). Logged `rebased`/`merged`.
2. **Rung 1 — Model self-heal (cap 2 *true-overlap* re-emit tries).** On conflict the result pastes the *live* `neighbourhood`, **sized to `max(8, span_lines)+margin`** so a wide edit sees enough of HEAD to re-anchor its actual region (fixes MF7). `Change.retry` increments **only when `charge_retry==true`** — a conflict caused purely by another mind advancing HEAD in a *disjoint* region does not burn the budget; the mind is re-shown fresh HEAD and its disjoint edit fast-merges (fixes F2). At `retry >= 2` on genuine overlap, stop asking this mind.
3. **Rung 2 — Resolver mind (only on a true overlapping conflict).** Write `conflicts/<refKey>.<round>.rej` = { base region, mind-A's applied result, mind-B's intended ops verbatim, **live HEAD hash**}. Spawn one resolver mind; its `edit_file` output goes back through the same locked, apply-checked, identity-guarded path. Because it re-anchors against whatever HEAD is at *its* commit time (also read in-lock), late HEAD churn just makes it re-conflict and retry, never mis-merge.
4. **Rung 3 — Deterministic reject.** If even the resolver's ops don't apply, reject; `work/` is left at the **last good HEAD**. The conflict record persists for next round.

Invariant across rungs: **no code path writes model-supplied bytes without a successful unique, identity-verified `apply` (or an exclusive whole-buffer replace passing the same check) followed by a successful atomic work-write.** Silent-wrong has no code path; the worst outcome is a rejected commit.

### 5.2 Full-file conflict gets its own prompt (fixes MF4)

A `write_file` conflict does not paste a SEARCH/REPLACE neighbourhood the writer can't express. Its `conflict.full_diff` carries the **base→HEAD diff** ("the file changed in these 2 places since you read it"), and the prompt shows the current full HEAD and asks the mind to **re-emit the full file on top of current HEAD**. The re-emitted content re-lowers to a whole-buffer replace against the now-current base and commits. Phase 3 replaces the whole-buffer anchor with per-hunk diff so a disjoint one-liner auto-merges without any re-prompt.

### 5.3 Semantic-merge hint (fixes MF8)

A textually-clean `kind==.merge` on a shared file can still be *semantically* broken (e.g. A changes a signature, B edits a call site to the old arity). The VCS cannot catch logic conflicts, but it **must not report bare success** on a cross-mind merge. On `.merge`:
- the success string is `" (merged with a concurrent change — unverified)"`, not bare success;
- the commit is tagged so the round's existing static cross-file interface-reconciliation + smoke gate (project memory: `multifile-interface-and-api-smoke`, `rsi-runtime-smoke-gate`) runs specifically on merged files;
- on gate failure, both contributing minds get a next-round note: *"your merged change to `<path>` may conflict with mind `<X>`'s concurrent edit."*

---

## 6. Tool + prompt surface the 20B emits

**The model's contract is unchanged.** It still emits an `edit_file` op list, or Aider SEARCH/REPLACE narration (map: parseNarrated), or a `write_file` full content. **No new version arg, no base hash.** The engine captures base + `base_seq` + per-op identity from the bytes the mind just read; the model never names a version (constraint 3).

- **On `committed`** (fast path / clean rebase): the today success string (map: `"edited <path> — N op(s) applied, file is now B bytes"`), suffixed `" (merged with a concurrent change — unverified)"` when `kind==.merge` (§5.3). Model does nothing.
- **On `conflict` (edit/narrated):** an actionable re-read prompt in bufedit's own reject vocabulary (in-distribution), with the neighbourhood **sized to the edit span**:
  ```
  edit failed: the file changed since you read it — your anchor "<first 60 chars>"
  is no longer present (or now matches 2 places / re-matched a different line).
  Current lines around where you aimed:
  <neighbourhood: max(8, your edit span)+margin live lines from HEAD>
  Re-emit your SEARCH block against THESE current lines.
  ```
  The model discovers the base moved *implicitly* — the same failure it is trained to fix by re-reading and re-anchoring; it never needs to know a teammate caused it. The ladder caps attempts so it cannot livelock, and pure-churn conflicts don't count against the cap (§5.1).
- **On `conflict` (full `write_file`):** the diff-based re-write prompt (§5.2).

**Phase-3 optional advisory hint (pure steering, opt-in, never load-bearing):** a `claim_region(path,[lines])` tool that records an fmtx-guarded advisory lease and adds one line to other minds' prompts (`note: mind 3 is editing app.zig:40-80`). It reduces collision *frequency* only; a 20B that ignores it costs nothing; it is **never** consulted in the commit path. Deleted from v1 (F8) — it is a second shared mutable structure whose only correctness contribution is a data-race surface.

---

## 7. Interop with structural ownership + `--quick`

**Ownership stays the default and the fast path** (map: OWNERSHIP). The VCS is the path for *deliberate* sharing.

- Ownership soft-reject runs **first**, unchanged (round 1 strict, round 2+ rescue). If it rejects, `commit` is never reached. In the common partitioned case each file has one writer; every commit is a trivial fast-forward (`base_seq == ref.seq`, `rebased=false`): one `apply` that always succeeds, one object, one ref rename. The rebase/guard branches are never taken.
- When ownership *permits* a shared write (round 2+ rescue, or an explicitly shared file), the VCS makes it safe. **Ownership decides *whether* two minds may touch a file; the VCS decides *how* their writes reconcile** (constraint 5). A mind that ignores the soft-reject and writes anyway now gets *merged* instead of *lost* — strictly safer than today.
- `fileOwnedBy` / `my_files` (map: [tools.zig:2822]) untouched; owned files keep the larger read budget; base capture reuses the read the mind already does — no extra read.

**`--quick` (single mind, oneshot, one round — no cross-mind contention):** gate the sidecar behind `Vcs.enabled=false` (known from run.zig: `doMoment` inline [run.zig:723] vs `grp.concurrent` [run.zig:724-732]). With `enabled=false`, `writeFile`/`editFile` take the **exact original code path** — no ref/object/log/rebase — **except** the plain `Dir.writeFile` [tools.zig:720/816] is upgraded to `writeWorkFileAtomic` (pinned temp+rename). Strictly safer at ~zero cost (one extra `rename`); no `.vcs/` dir is created for single-mind runs (constraint 6). The only fast-path addition is one boolean check.

---

## 8. Corruption and concurrency guarantees — critic fixes folded in

All-or-nothing + resolved-against-known-base + never-partial (constraint 2) holds at **four** layers: bufedit for the byte splice; pinned temp+rename for the disk landing; object-before-ref fsync ordering for durability; the intent journal for crash-recovery validation.

### 8.1 Failure-mode table

| Failure | Outcome | Why no corruption |
|---|---|---|
| Crash during work-file write | Old bytes intact | pinned temp+rename; target only swapped atomically; tmp `errdefer`-unlinked |
| Crash after work-write, before ref | Reconcile finishes forward **iff** matching `pending` intent proves validated target; else rolls **back** to last-good HEAD | intent-first journaling (**C2**); disk never blind-trusted |
| Crash after object, before ref (power loss) | Old ref stands; object durable | object fsync'd **before** ref (**C3**); hash-named object always dereferences |
| Object tmp short-write / ENOSPC | Discarded; commit refused before work/ touched | re-hash==expected + len check before rename (**C6/C7**); `errdefer unlink` |
| Two minds commit same file | Serialized by files_mtx; second rebases on `seq` | HEAD read in-lock ⇒ no TOCTOU; second fast-merges or conflicts |
| Second mind overlaps first | `conflict` → ladder | bufedit rejects *before* mutating |
| Unique-but-wrong match after teammate delete | `conflict` (identity guard) | bracketing base lines don't survive (**MF1/MF3/MF6**) |
| Content reverts to prior hash (ABA) | Correctly treated as rebased; guard runs | `rebased` from `seq`, not hash (**F5**) |
| External `git checkout`/save in `--embed` | `conflict`/re-adopt, user edit preserved | disk verified `== ref.head` in-lock; disk authoritative (**C5/C4/MF5/F6**) |
| Target file open by editor/AV (sharing violation) | Commit refused; ref not advanced; bounded retry **outside** lock | ref advances only after work-write success (**C4**); no retry under lock |
| Full-file write onto changed file | `conflict` with base→HEAD diff re-prompt | whole-buffer anchor vanishes; rewrite recoverable, not dropped (**MF4**) |
| Ref/log/object half-written | Old state stands / dropped | temp+rename; content-hash names; log advisory |
| `refKey` (128-bit) collision | Chained, VCS-tracked | stored `npath` chain; never downgraded to untracked (**C9**) |
| `work/` is a junction to a live repo | Untouched `.git`; disk authoritative | never write into `.git`; never shell git; sidecar run_dir-local |
| `.vcs/` deleted mid-run | Degrades to first-touch re-adoption | HEAD re-seeded from disk; more conflicts, never wrong writes |
| `.vcs/` full (disk-full) | Commit refused before work/ touched; no litter | ENOSPC checked at object-write; `errdefer` cleans tmps (**C7**) |

### 8.2 Concurrency guarantees

- **In-lock read-apply-write is the sole HEAD authority.** No in-RAM HEAD cache; HEAD is read from disk (or the verified disk file in embed) inside `files_mtx`. Constraint 7 holds.
- **`last_seen` deleted, `leases` removed from v1 (F1/F8).** The two shared mutable structures the old design touched *outside* the lock — the data-race / UAF surface (the arena→gpa segfault class this codebase was already bitten by) — are gone. Any future advisory structure is fmtx-guarded.
- **Retry ladder does not mis-charge HEAD churn (F2).** A disjoint mover's conflict sets `charge_retry=false`; only true-overlap conflicts consume the cap. Clean edits are no longer wrongly rejected under load.
- **GC is race-free (C8/F3/MF9).** GC takes `files_mtx`, snapshots the pin-set atomically = {every live HEAD} ∪ {every live HEAD's `parent`} ∪ {objects referenced by any `intent`} ∪ {objects referenced by any open `conflicts/*.rej`} ∪ {keep-last-N per file}, records `epoch_snapshot = lock_epoch`, releases, then unlinks *outside* the lock **only** objects absent from the pin-set **and** untouched by any commit whose `epoch >= epoch_snapshot`. It therefore can never unlink a just-written-not-yet-reffed object, a fresh commit's parent, an intent target, or an open-conflict blob.
- **Bounded critical section, watchdog-safe (F4/F7).** The section contains `readObject`/disk-verify + `apply` + hash + `writeObjectDurable` + `writeWorkFileAtomic` — three full-file passes for the largest `--embed` files. For v1 the single global `files_mtx` over-serializes but is correct; the acquire is **cancelable** (watchdog can reclaim a queued fiber) while only the mutation phase is uncancelable (a holder never leaves HEAD half-updated). No `panic` under the lock. Per-`refKey` lock table is brought forward **specifically for `--embed`** (the large-file case) in Phase 2 to bound the window (F4).

### 8.3 Critic-fix cross-reference

C1 §4.6 · C2 §4.3/§4.4 · C3 §4.3 · C4 §4.3 · C5 §4.2 · C6 §2/§4.3 · C7 §4.3/§4.6 · C8 §8.2-GC · C9 §2/§4.5 · F1 §3/§8.2 · F2 §4.2/§5.1 · F3 §8.2-GC · F4 §8.2/§9-Phase2 · F5 §3/§4.2 · F6 §4.2 · F7 §4.2 · F8 §3/§6 · MF1 §3/§4.3 · MF2 §4.1 · MF3 §3/§4.1 · MF4 §4.1/§5.2 · MF5 §4.2 · MF6 §3.1 · MF7 §5.1 · MF8 §5.3 · MF9 §8.2-GC.

### 8.4 Concerns that are NOT real given the substrate (stated, then moved on)

- **"EXDEV byte-copy corrupts the user tree" for a junction (C1 sub-point 1).** A Windows *directory junction* never crosses volumes, so `work/` and a temp *beside the target inside work/* are always one volume — EXDEV cannot arise there. We still pin the rename syscall (§4.6) and refuse cross-volume `--embed` at startup, because the real risk is `std.fs.rename`'s silent copy-degrade, not the junction geometry. Addressed, not by accident.
- **"First-touch adoption races two concurrent minds" (MF5-happy / F6-happy path).** Both minds enter `commit` under the *same* global `files_mtx`; the first seeds init (seq 0) and commits, the second sees a non-null ref and rebases. The intra-worker case is serialized and correct by construction. The *only* real residual is an *external* writer into an `--embed` tree, which §4.2's disk-authoritative verify + §4.1's stat-snapshot read handle.
- **"Global lock throughput collapse" (F4) as a *correctness* claim.** It is not a correctness issue — it is throughput. The section is bounded, the acquire is cancelable, and per-key locking is scheduled for the large-file case in Phase 2. For swarm sizes in play with partitioned ownership, the fast path is a single fast-forward per file and contention is negligible.
- **"Semantic/logic conflicts merge cleanly into a broken build" (MF8).** Real, but inherent to *any* anchor/text merge (a line-ID CRDT would also merge them). The VCS's job is no silent *byte-level* wrong merge; §5.3 adds the honest "unverified" report + smoke-gate hook rather than pretending to catch logic conflicts.
- **`base/` second namespace (earlier draft).** Removed; round-start snapshots are just pinned objects, so there is nothing to keep coherent.

---

## 9. v1 slice, then Phases 2–3

**v1 SLICE — fewest moving parts that deliver the core value (kills the lost-update + the plain-write corruption, safely):**
1. `writeWorkFileAtomic` with the **pinned rename** (§4.6), replacing both plain `Dir.writeFile` sites [tools.zig:720/816]. *Ships alone, even with the VCS off — strictly safer today.*
2. The **first-class `bufedit.Applied.loci`** extension (§3.1) + its unit test. Load-bearing for the identity guard, so it is v1, not deferred.
3. `src/worker/vcs.zig`: `refKey` (xxh3-128), `Ref` read/write (temp+rename), content-addressed `objects/` (durable write + re-hash verify), `Change` lowering, per-op **anchor min-unique expansion + identity capture** (§4.1), and `commit()` with the EXISTING-file rebase branch + NEW-file first-touch adoption + **seq-based `rebased`** + **identity-verified guard** + **intent-first / object-before-ref / work-before-ref / ref-last** `writeCommit` (§4.3) + startup **recover()** (§4.4), all under `w.files_mtx` with a **cancelable acquire** (§4.2).
4. **`--embed` disk-authoritative** HEAD verify (§4.2) — because `--embed` at a live repo is exactly where silent clobber is worst; it is cheap (one hash of the file already being read) and closes C5/C4/MF5/F6 in v1.
5. Route `writeFile`/`editFile` through `commit()`, gated on `Vcs.enabled` (off for `--quick`).
6. Conflict result = the re-anchor prompt (edit/narrated) **or** the diff re-write prompt (full-file, §5.2), neighbourhood **sized to span** (§5.1). **Ladder rungs 0–1** (auto-rebase + churn-aware self-heal, cap 2). No resolver mind, no GC yet.

That slice satisfies constraints 1–7 and folds every HIGH finding (C1, C2, C4, C5, F1, F2, MF1, MF3, MF4, MF6) into v1 — none is deferred.

**Phase 2 — hardening + weak-model recovery:**
- Ladder rung 3 (deterministic reject) + rung 2 (resolver mind) with `conflicts/*.rej`.
- Keep-last-N GC with the atomic pin-set (§8.2), and shared-content object dedup.
- Semantic-merge smoke-gate hook + cross-mind note (§5.3).
- Per-`refKey` lock table **for `--embed` large files** to bound the critical section (F4).

**Phase 3 — parallelism + finer merges:**
- Fine per-hunk diff-vs-base for `write_file` so a full rewrite auto-merges disjoint regions (§5.2).
- Per-`refKey` lock table for all files (multi-file throughput), carefully ordered against the manifest RMW.
- Optional `claim_region` advisory lease + `note:` prompt line (pure steering, fmtx-guarded).

---

## 10. Test plan

**Deterministic unit tests (`src/worker/vcs.zig` test block + one `bufedit` test), no model:**

*bufedit extension*
- `loci` correctness: an op that matches after two higher-offset splices reports the true post-splice `matched_offset`.

*core commit*
- New file (create) → HEAD seq=1, object dereferences, `work/` bytes match.
- First-touch adoption: pre-existing on-disk file → init seq=0 then edit seq=1; HEAD = edited bytes.
- Fast-forward: single writer, `base_seq == ref.seq` → `rebased=false`, one object.
- **Auto-rebase (disjoint):** A edits region X; B (base = pre-A HEAD) edits region Y → B `committed{rebased,merge}`; final bytes contain both.
- **Conflict (same region):** A edits X; B (stale) edits X → `conflict`, `work/` == A's bytes, no marker.
- **Ambiguous anchor:** duplicate anchor text unresolvable in base → `conflict`, never a pick.
- **Min-unique expansion:** a short/duplicated anchor is expanded and then applies uniquely where it previously would have been ambiguous.

*the hardened guards (each is a critic scenario)*
- **Identity guard / MF1:** HEAD where the op's anchor survives *uniquely but on a different line* (teammate deleted the real target; an identical line remains elsewhere) → `conflict "anchor-drift"`, not a silent wrong merge.
- **Narrated `base_offset` / MF3:** a SEARCH/REPLACE (no `at`) op past line 1 rebased onto a shifted HEAD → identity guard runs correctly (no spurious fire, and fires on a genuine identity break).
- **ABA / F5:** A adds a block (h0→h1), B reverts it (h1→h0-by-content); a third op with `base_seq` at h0 → `rebased=true` (seq advanced), guard runs, log linear.
- **Churn not charged / F2:** A commits a disjoint region between B's two attempts → B's first conflict has `charge_retry=false`; B's disjoint edit fast-merges on retry without consuming the cap.
- **Full-file conflict / MF4:** `write_file` onto a file a teammate one-line-changed → `conflict` carries `full_diff`; re-emit full file against HEAD → `committed`.
- **Neighbourhood sizing / MF7:** a 15-line edit conflict returns a neighbourhood ≥ its span.

*atomicity + recovery (fault injection)*
- **Object-before-ref / C3:** kill after object+intent, before ref → recovery finishes forward (intent matches); object present.
- **Intent-validated recovery / C2:** kill after work-write, before ref, *with* matching intent → forward-finish; kill after a *raw* (no-intent) disk mutation → **roll back** to last-good HEAD (proves would-be-rejected bytes are not adopted).
- **Sharing violation / C4:** stub `writeWorkFileAtomic` to fail (locked) → ref does **not** advance; intent cleared; bounded retry outside lock; HEAD == disk still consistent.
- **ENOSPC / C6/C7:** stub object write to short-write → commit refused *before* work/ touched; tmp unlinked; no litter in `work/`.
- **Pinned rename / C1:** assert the rename path never byte-copies (mock the syscall; fail EXDEV → commit refused, no plain write).
- **Atomicity:** huge buffer, interrupt mid-write → only old-or-new ever observable.

*embed*
- **External write / C5:** seed HEAD, mutate `work/<f>` out-of-band (≠ ref.head), then commit → disk re-adopted, mind forced to rebase, external bytes preserved (not clobbered).

*GC (Phase 2)*
- **Pin-set / C8/F3/MF9:** commit under lock races a GC sweep; assert GC never unlinks the fresh commit's object, its parent, an intent target, or an open-`.rej` blob (drive via `lock_epoch` snapshot).

**Live two-minds-one-file scenario on gpt-oss:20b:**
- Harness: one shared file `app.zig`, two functions; two minds, one round, ownership deliberately shared (round-2 rescue) so both may write.
- **Disjoint:** A edits `fn handle`, B edits `fn route` → both `committed`, final file has both, log = one `edit` + one `merge`, zero conflicts (auto-rebase on a real weak model).
- **Contended:** both edit the same function body → one `committed`, the other `conflict` → rung-1 self-heal re-emit against span-sized `neighbourhood` → `committed{merge}`; final file whole, no `<<<<<<<`, `work/` a valid apply-result at every observation.
- **Churn-not-charged (F2, live):** three minds on one hot file; assert a disjoint mover is not rejected by others' HEAD churn.
- **Livelock guard:** genuinely irreconcilable overlap → rung 1 caps at 2, rung 3 rejects, `work/` at last-good HEAD; the run does not spin.
- **`--embed` live:** point `work/` at a scratch git repo; mid-run run `git checkout` on a target file; assert the mind's next commit conflicts/re-adopts and the checkout is preserved.
- **`--quick` regression:** single-mind oneshot → `Vcs.enabled==false`, no `.vcs/`, wall-clock within noise of baseline, write still through pinned temp+rename (no torn file under an injected mid-write kill).

---

**Map refs relied on:** writeFile [tools.zig:720], editFile [tools.zig:786/803/816], lockFiles/unlockFiles [tools.zig:131-134] (files_mtx), safeRel [tools.zig:2793], fileOwnedBy [tools.zig:2822], concurrency model [run.zig:723-732], worker mutexes [run.zig:220-222], bufedit.zig (apply / parseNarrated / OpKind / reject reasons / content-anchor KEY PROPERTY + full-write LIMITATION).

**Source note:** authored against the authoritative substrate map; `src/worker/{tools,bufedit,run}.zig` live in the sibling nl-veil/neuron-loops tree, not this neuron-db checkout. The single assumed-but-not-yet-present substrate change is `bufedit.Applied.loci: []MatchLocus` (§3.1) — a small, contained addition, made **first-class in v1** because the identity guard (the sole defense against MF1) depends on it, with its own bufedit unit test. Everything else uses substrate the map already states exists (`bufedit.apply` content-anchor merge, `parseNarrated`, `files_mtx`, `safeRel`, ownership).
