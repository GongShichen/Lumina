#!/usr/bin/env bash
set -euo pipefail

python3 - <<'PY'
from pathlib import Path
import re
import sys

DECL_RE = re.compile(
    r'^\s*(?:@\w+(?:\([^)]*\))?\s*)*'
    r'(?:(?:public|internal|private|fileprivate|open)\s+)?'
    r'(?:(?:final|indirect)\s+)?'
    r'(?:actor|class|struct|enum|protocol|typealias)\s+'
    r'([A-Za-z_][A-Za-z0-9_]*)'
)
EXT_RE = re.compile(r'^\s*(?:(?:public|internal|private|fileprivate)\s+)?extension\s+')


def masked_lines(lines):
    state = {"block": False, "string": False, "triple": False}
    result = []
    for line in lines:
        output = []
        i = 0
        while i < len(line):
            char = line[i]
            pair = line[i:i + 2]
            triple = line[i:i + 3]
            if state["block"]:
                if pair == "*/":
                    output.extend("  ")
                    i += 2
                    state["block"] = False
                else:
                    output.append(" ")
                    i += 1
            elif state["string"]:
                if state["triple"]:
                    if triple == '"""':
                        output.extend("   ")
                        i += 3
                        state["string"] = False
                        state["triple"] = False
                    else:
                        output.append(" ")
                        i += 1
                elif char == "\\":
                    output.extend("  ")
                    i += 2
                elif char == '"':
                    output.append(" ")
                    i += 1
                    state["string"] = False
                else:
                    output.append(" ")
                    i += 1
            elif pair == "//":
                output.extend(" " * (len(line) - i))
                break
            elif pair == "/*":
                output.extend("  ")
                i += 2
                state["block"] = True
            elif triple == '"""':
                output.extend("   ")
                i += 3
                state["string"] = True
                state["triple"] = True
            elif char == '"':
                output.append(" ")
                i += 1
                state["string"] = True
            else:
                output.append(char)
                i += 1
        result.append("".join(output))
    return result


failures = []
for path in sorted(Path("Sources").rglob("*.swift")):
    lines = path.read_text().splitlines()
    depth = 0
    declarations = []
    extensions = 0
    for line in masked_lines(lines):
        if depth == 0:
            match = DECL_RE.match(line)
            if match:
                declarations.append(match.group(1))
            elif EXT_RE.match(line):
                extensions += 1
        depth += line.count("{") - line.count("}")

    if len(declarations) > 1:
        failures.append(f"{path}: contains multiple top-level declarations: {', '.join(declarations)}")
    elif len(declarations) == 1 and declarations[0] != path.stem:
        failures.append(f"{path}: top-level declaration {declarations[0]} does not match filename")
    elif extensions and declarations:
        failures.append(f"{path}: contains both a declaration and top-level extension")
    elif extensions and "+" not in path.stem:
        failures.append(f"{path}: extension-only files must use Type+Purpose.swift naming")

if failures:
    print("Filename alignment check failed:")
    for failure in failures:
        print(f" - {failure}")
    sys.exit(1)

print("Filename alignment check passed.")
PY
