#!/usr/bin/env python3
"""
Strict old-style plist structural validator for project.pbxproj.

Tokenizes the whole file (comments, quoted strings, identifiers, hex IDs,
numbers, punctuation) and verifies:
 1. The token stream is grammatical at the top level: `ID = VALUE ;`
    where VALUE is a dict `{ ... }`, a list `( ... )`, or a scalar.
 2. Every dict entry follows `key = VALUE ;` grammar.
 3. All UUIDs referenced in group children / build phases have definitions.
 4. No stray tokens (the class of corruption that broke CI 34164191391).
"""
import re
import sys

path = "/home/z/my-project/Shirox/Shirox.xcodeproj/project.pbxproj"
text = open(path).read()

pos = 0
n = len(text)
tokens = []


def fail(msg):
    line = text.count("\n", 0, pos) + 1
    print(f"PARSE ERROR line {line}: {msg}")
    sys.exit(1)


while pos < n:
    c = text[pos]
    if c in " \t\r\n":
        pos += 1
        continue
    if text.startswith("//", pos):
        end = text.find("\n", pos + 2)
        pos = n if end == -1 else end
        continue
    if text.startswith("/*", pos):
        end = text.find("*/", pos + 2)
        if end == -1:
            fail("unterminated comment")
        pos = end + 2
        tokens.append(("comment", text[pos - 40:pos].splitlines()[-1] if False else ""))
        continue
    if c == '"':
        i = pos + 1
        while i < n:
            if text[i] == "\\":
                i += 2
                continue
            if text[i] == '"':
                break
            i += 1
        if i >= n:
            fail("unterminated string")
        tokens.append(("str", text[pos:i + 1]))
        pos = i + 1
        continue
    if c == "/" or c == "*":
        # A stray slash or star OUTSIDE a comment/string = corruption.
        # (Operators like / * never appear in old-style plists.)
        fail(f"stray punctuation {c!r} outside comment/string")
    m = re.match(r"[0-9A-Fa-f]{24}", text[pos:])
    if m:
        tokens.append(("id", m.group(0)))
        pos += 24
        continue
    if c == "/" or c == "*":
        # A stray slash or star OUTSIDE a comment/string = corruption.
        # (Operators like / * never appear in old-style plists.)
        fail(f"stray punctuation {c!r} outside comment/string")
    # Bare (unquoted) string: pbxproj values like
    # path = System/Library/Frameworks/WebKit.framework; contain slashes
    # mid-word. Starts with a non-special, non-slash char; may contain
    # internal slashes.
    m = re.match(r"[^/ \t\r\n{}();=,\"*][^ \t\r\n{}();=,\"]*", text[pos:])
    if m:
        tokens.append(("ident", m.group(0)))
        pos += len(m.group(0))
        continue
    if c in "{}();=,":
        tokens.append((c, c))
        pos += 1
        continue
    m = re.match(r"-?[0-9]+(\.[0-9]+)?", text[pos:])
    if m:
        tokens.append(("num", m.group(0)))
        pos += len(m.group(0))
        continue
    fail(f"unexpected character {c!r}")

# Grammar walk (skip comments).
toks = [t for t in tokens if t[0] != "comment"]
i = 0


def parse_value():
    global i
    kind = toks[i][0]
    if kind == "{":
        i += 1
        while toks[i][0] != "}":
            if toks[i][0] not in ("ident", "str", "id"):
                fail(f"expected key, got {toks[i]}")
            i += 1
            if toks[i][0] != "=":
                fail(f"expected '=' after key, got {toks[i]}")
            i += 1
            parse_value()
            if toks[i][0] != ";":
                fail(f"expected ';' after value, got {toks[i]}")
            i += 1
        i += 1
        return
    if kind == "(":
        i += 1
        while toks[i][0] != ")":
            parse_value()
            if toks[i][0] == ",":
                i += 1
            elif toks[i][0] != ")":
                fail(f"expected ',' or ')' in list, got {toks[i]}")
        i += 1
        return
    # scalar
    if kind in ("id", "ident", "str", "num"):
        i += 1
        return
    fail(f"bad value start {toks[i]}")


# The entire pbxproj is ONE outer dictionary:
#   { archiveVersion = ...; classes = {...}; objects = { ALL SECTIONS };
#     rootObject = ID; }
parse_value()
if i != len(toks):
    fail(f"trailing tokens after outer dict: {toks[i:i+3]}")

# Cross-reference check: every ID used in children lists must be defined.
ids_used = set(re.findall(r"\(([0-9A-Fa-f]{24} /\* [^*]+ \*/[,]?\s*)+\)", text[:0]) or [])
defined = set(m.group(1) for m in re.finditer(r"(?m)^\s+([0-9A-Fa-f]{24}) /\* [^*]+ \*/ = \{", text))
refs_in_children = set(m.group(1) for m in re.finditer(r"^\s+([0-9A-Fa-f]{24}) /\* [^*]+ \*/,\s*$", text, re.M))
missing = refs_in_children - defined
print(f"tokens: {len(tokens)} — outer plist dict parsed cleanly")
print(f"defined IDs: {len(defined)}, child refs: {len(refs_in_children)}, missing definitions: {len(missing)}")
if missing:
    print("MISSING:", sorted(missing)[:10])
    sys.exit(1)
print("PLIST STRUCTURE VALID")
