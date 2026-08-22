MODEL = "deepseek-v4-flash"
BASE_URL = "https://api.deepseek.com/v1"

# Long-tail conversations. Each one is deliberately shaped to keep going past the point where
# the recency window rolls and the rolling summary has to carry continuity — that is where the
# reported failures live (restarts, lost middles, empty replies).

BUILD = [
    "Create a directory `csvstat` and in it write `csvstat.py`: a small CLI that reads a CSV file and prints, per numeric column, the count, min, max, mean and median. Use only the Python standard library. Write the file, then show me the code you wrote.",
    "Now write `sample.csv` in the same directory with 12 rows and 4 columns: two numeric (`price`, `qty`), one date (`when`), one text (`label`). Then actually RUN csvstat.py against it and show me the real output.",
    "The median is wrong for even-length columns — it should average the two middle values. Fix it in csvstat.py and re-run to prove the fix.",
    "Add a `--json` flag that emits the same stats as JSON instead of a table. Run it both ways to show both outputs still work.",
    "Add a `tests.py` with at least 5 assertions covering median on even and odd lengths, empty columns, and non-numeric columns. Run it and show the result.",
    "One of the columns in sample.csv is text. What does your tool do with it right now, and is that the right behaviour? Decide, then make the code match your decision.",
    "Summarise everything in csvstat/ right now: every file, what each does, and what still isn't handled. Be specific and base it on the actual files, not memory.",
    "Add a `--column NAME` flag to restrict output to one column, run it, then re-run tests.py to confirm nothing regressed.",
    "Without re-reading the files, tell me from memory what the median fix was and which turn we made it in.",
]

RESEARCH = [
    "Research how SQLite's WAL mode actually works and write `wal-notes.md` with: what the WAL file is, how checkpointing works, what happens on crash, and the main tradeoffs vs rollback journal. Cite the sources you actually fetched.",
    "Now check specifically what happens to readers DURING a checkpoint, and whether readers can block a checkpoint. Add a section to wal-notes.md.",
    "What are the failure modes of WAL on network filesystems? Add that too, and be explicit about what you could and could not verify from a source.",
    "Re-read wal-notes.md and list any claim in it that you did NOT verify from a fetched source. Be honest — I want the unverified ones named.",
    "Fix the document: remove or clearly mark every unverified claim you just listed. Show me the diff of what changed.",
    "Give me a 5-bullet executive summary of wal-notes.md, based on the file as it now exists.",
]

# Deliberately drives many cheap turns to roll the recency window and force the rolling-summary
# path, then asks a question only answerable from the DROPPED middle. This is the direct test of
# the summary-ledger fix: a run that has forgotten its own middle will answer this wrong.
CONTINUITY = [
    "Let's play a precision game. I'll give you facts one at a time. Fact 1: the deploy key is named `orbital-7`. Just acknowledge briefly.",
    "Fact 2: the staging database is `pg-eu-west-2b`. Acknowledge briefly.",
    "Fact 3: the release manager is Priya. Acknowledge briefly.",
    "Fact 4: the rollback window is 45 minutes. Acknowledge briefly.",
    "Fact 5: the incident channel is #ops-red. Acknowledge briefly.",
    "Now write a file `notes/facts.md` recording all five facts so far, then confirm what you wrote.",
    "Fact 6: the canary percentage is 7%. Acknowledge briefly.",
    "Fact 7: the on-call rotation flips at 09:00 UTC. Acknowledge briefly.",
    "Write a 400-word explanation of blue-green deployment. Just prose, no tools.",
    "Write another 400 words, this time on canary deployment specifically. Just prose.",
    "Write another 400 words on feature flags as a release strategy. Just prose.",
    "Write another 400 words on database migration safety during zero-downtime deploys. Just prose.",
    "Without reading any file, what was Fact 1 and Fact 3? Answer from context only.",
    "Now read notes/facts.md and tell me whether your previous answer matched what you had written down.",
    "What is the rollback window, and who is the release manager? Answer directly.",
]

# Exercises the exact failure this work targeted: a mid-run meta-question. A healthy run answers
# it once and returns to the task; the old behaviour fixated and re-litigated it every cycle.
STEER = [
    "Create `fib/fib.py` implementing fibonacci three ways: naive recursion, memoized, and iterative. Then run it for n=25 and print the timings for all three.",
    "are you stuck?",
    "Good. Now add a fourth implementation using matrix exponentiation and benchmark it against the others at n=200.",
    "why is this taking so long?",
    "Finish the benchmark and write the results into `fib/RESULTS.md`, then show me the file.",
    "What did I ask you about two messages ago? Answer from context.",
]

# Non-file work with tools — the class that used to bank nothing into memory, so a later turn
# had no record it happened.
DEBUG = [
    "Write `buggy/parse.py`: a function `parse_kv(text)` that turns lines of `key=value` into a dict, plus a `__main__` that runs it on a sample with blank lines, a line with no `=`, a line with multiple `=`, and leading/trailing spaces. Run it and show what happens.",
    "It should not crash on a line with no `=` — those lines should be skipped. And a value containing `=` must be preserved intact. Fix and re-run.",
    "Now, WITHOUT writing any files, reason through what parse_kv does with a key that repeats. Explain what happens and what you think it should do.",
    "Apply the decision you just made, then re-run to prove it.",
    "What was the reasoning you gave two turns ago about repeated keys? Restate it from context.",
]

SCENARIOS = [
    {"name": "build", "turns": BUILD},
    {"name": "continuity", "turns": CONTINUITY},
    {"name": "steer", "turns": STEER},
    {"name": "debug", "turns": DEBUG},
    {"name": "research", "turns": RESEARCH},
]
