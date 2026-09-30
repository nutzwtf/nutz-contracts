#!/usr/bin/env python3
# scripts/mutation-siblings.py — the other mutants forge would generate on the spans of a list of survivors.
# usage: scripts/mutation-siblings.py survivors.txt > siblings.txt
# forge skips the remaining mutants of a span once one of them has survived, and its report does not name
# them. Given the survivors (the `L<line>:<col>  `<original>` -> `<mutant>`` lines), this prints, in the same
# format, every other operator of the same family on the same span, for scripts/mutation-rerun.py to run.
# The family is read off the survivor: comparison, arithmetic, logical, increment or compound assignment.
import re
import sys

FAMILIES = [
    ["==", "!=", "<", "<=", ">", ">="],
    ["+", "-", "*", "/", "%", "**", "&", "|", "^", "<<", ">>"],
    ["||", "&&"],
    ["+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "<<=", ">>="],
]
INCREMENTS = ["{v}++", "++{v}", "{v}--", "--{v}"]
line_re = re.compile(r"^\s*L(\d+):(\d+)\s+`(.*)` -> `(.*)`$")
seen = set()


def split_op(orig, mut):
    """The operator that changed: the middle of the two strings once their common prefix and suffix are off."""
    p = 0
    while p < min(len(orig), len(mut)) and orig[p] == mut[p]:
        p += 1
    s = 0
    while s < min(len(orig), len(mut)) - p and orig[-1 - s] == mut[-1 - s]:
        s += 1
    # `==` against `<=` share a `=`: widen the middle to whole operator tokens on both sides.
    ops = set("=!<>+-*/%&|^")
    while p > 0 and orig[p - 1] in ops:
        p -= 1
    while s > 0 and orig[len(orig) - s] in ops:
        s -= 1
    return orig[:p], orig[p : len(orig) - s].strip(), mut[p : len(mut) - s].strip(), orig[len(orig) - s :]


for raw in open(sys.argv[1]):
    m = line_re.match(raw.rstrip("\n"))
    if not m:
        continue
    line, col, orig, mut = int(m[1]), int(m[2]), m[3], m[4]
    inc = re.fullmatch(r"(\+\+|--)?(\w[\w.\[\]]*)(\+\+|--)?", orig)
    if inc and (inc[1] or inc[3]):
        v = inc[2]
        variants = [t.format(v=v) for t in INCREMENTS]
    else:
        prefix, op, mop, suffix = split_op(orig, mut)
        fam = next((f for f in FAMILIES if op in f), None)
        if fam is None:
            print(f"# no family for L{line}:{col} `{orig}` -> `{mut}`", file=sys.stderr)
            continue
        # forge also turns `a || b` into `a == b` and `a != b`.
        alts = list(fam) + (["==", "!="] if fam == FAMILIES[2] else [])
        lead = " " if prefix.endswith(" ") else ""
        trail = " " if suffix.startswith(" ") else ""
        variants = [f"{prefix.rstrip()}{lead}{a}{trail}{suffix.lstrip()}" for a in alts]
    for v in variants:
        if v == orig or v == mut or (line, col, v) in seen:
            continue
        seen.add((line, col, v))
        print(f"  L{line}:{col}  `{orig}` -> `{v}`")
