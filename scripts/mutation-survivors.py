#!/usr/bin/env python3
# scripts/mutation-survivors.py — the survivors common to two `forge test --mutate --json` passes over one file.
# usage: scripts/mutation-survivors.py unit.json inv.json
# A mutant that any test fails on is killed, so the survivors of the run are those both passes let through
# (docs/setup/tools.md "Mutation tests" says why the run is two passes). Prints the kill rate and one line per
# survivor: `L<line>:<col>  `<original>` -> `<mutant>``, the format docs/security/mutation-*.md records.
import json
import sys


def report(path):
    """The JSON report is the last `{"summary": ...}` line of stdout; test events precede it."""
    last = None
    with open(path) as f:
        for line in f:
            if line.startswith('{"summary"'):
                last = line
    if last is None:
        sys.exit(f"{path}: no summary line; was the pass run with --json?")
    return json.loads(last)


def key(m):
    return (m["line"], m["column"], m["original"], m["mutant"])


if len(sys.argv) != 3:
    sys.exit("usage: mutation-survivors.py unit.json inv.json")
a, b = report(sys.argv[1]), report(sys.argv[2])
sa, sb = a["summary"], b["summary"]
if sa["total"] != sb["total"]:
    sys.exit(f"the passes generated different mutant sets ({sa['total']} vs {sb['total']}): same file, same commit?")
if sa["skipped"] or sb["skipped"]:
    # The report does not name them; they share a span with a survivor, so scripts/mutation-siblings.py on the
    # survivors covers them (docs/security/mutation-2026-09.md "Method").
    print(f"warning: skipped mutants (unit {sa['skipped']}, invariant {sb['skipped']}) are not in either list")
sur_a = [m for ms in a["survived_mutants"].values() for m in ms]
sur_b = {key(m) for ms in b["survived_mutants"].values() for m in ms}
both = sorted((m for m in sur_a if key(m) in sur_b), key=key)
invalid = max(sa["invalid"], sb["invalid"])
tested = sa["total"] - invalid
print(f"generated {sa['total']}, invalid {invalid}, tested {tested}")
print(f"unit pass killed {sa['killed']} (survived {len(sur_a)}); invariant pass killed {sb['killed']} (survived {len(sur_b)})")
print(f"survived both: {len(both)}; kill rate {100 * (tested - len(both)) / tested:.1f}%")
for m in both:
    print(f"  L{m['line']}:{m['column']}  `{m['original']}` -> `{m['mutant']}`")
