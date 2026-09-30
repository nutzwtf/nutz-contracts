#!/usr/bin/env python3
# scripts/mutation-rerun.py — applies listed mutants to a source file one at a time and runs a test filter on each.
# usage: scripts/mutation-rerun.py <src file> <mutant list> [forge test args...]
#   e.g. scripts/mutation-rerun.py src/NutzDistributor.sol survivors.txt --no-match-path 'test/{fork,unit}/**'
# The list holds `L<line>:<col>  `<original>` -> `<mutant>`` lines, as scripts/mutation-survivors.py prints them
# and as forge's JSON report spells them; other lines are ignored. Run it from a copy of the repo (a worktree with
# lib/ symlinked): the source is rewritten in place for each mutant and restored at the end, even on Ctrl-C.
# Prints KILLED (a test failed), SURVIVED (all passed), INVALID (did not compile) or ERROR (forge failed some
# other way: look, do not count) per mutant, then a tally.
# Three uses (docs/setup/tools.md "Mutation tests"): the invariant suites against the unit pass's survivors, an
# equivalent survivor under the default profile, and the sibling mutants of a span the runner skipped.
import re
import subprocess
import sys

if len(sys.argv) < 3:
    sys.exit("usage: mutation-rerun.py <src file> <mutant list> [forge test args...]")
src, listing = sys.argv[1], sys.argv[2]
forge_args = sys.argv[3:] or ["--match-path", "test/unit/**"]
pristine = open(src).read()
line_re = re.compile(r"^\s*L(\d+):(\d+)\s+`(.*)` -> `(.*)`$")
tally = {"KILLED": 0, "SURVIVED": 0, "INVALID": 0, "ERROR": 0, "NO-MATCH": 0}
try:
    for raw in open(listing):
        m = line_re.match(raw.rstrip("\n"))
        if not m:
            continue
        line, col, orig, mut = int(m[1]), int(m[2]), m[3], m[4]
        if " = " in orig and orig.endswith(";") and "=" not in mut:
            mut = orig[: orig.index(" = ") + 3] + mut + ";"  # a constant's mutant is printed as its new initializer
        lines = pristine.split("\n")
        text = lines[line - 1] if line <= len(lines) else ""
        if not text[col - 1 :].startswith(orig):
            status = "NO-MATCH"
        else:
            lines[line - 1] = text[: col - 1] + mut + text[col - 1 + len(orig) :]
            with open(src, "w") as f:
                f.write("\n".join(lines))
            # Always a forced build: forge 1.8.3's incremental build has been seen to leave a test harness that
            # inherits the mutated contract un-rebuilt, and a stale artifact reads as the wrong verdict either way.
            # No lint: `forge test` does not lint, and a tautology mutant (`x >= 0`) trips `deny = "warnings"`.
            b = subprocess.run(["forge", "build", "--force", "--no-lint"], capture_output=True, text=True)
            if b.returncode != 0:
                status = "INVALID" if "Compiler run failed" in b.stdout + b.stderr else "ERROR"
            else:
                r = subprocess.run(["forge", "test", "--fail-fast", *forge_args], capture_output=True, text=True)
                # A kill is a failing test, nothing else; any other non-zero exit is an environment problem.
                status = "SURVIVED" if r.returncode == 0 else "KILLED" if "[FAIL" in r.stdout else "ERROR"
        tally[status] += 1
        print(f"L{line}:{col} `{orig}` -> `{mut}`: {status}", flush=True)
finally:
    with open(src, "w") as f:
        f.write(pristine)
print(" ".join(f"{k.lower()} {v}" for k, v in tally.items() if v))
