#!/usr/bin/env python3
"""Read and write single values in a terraform.tfvars file.

    tfvars.py get <file> <name>
    tfvars.py set <file> <name> <value>

`get` prints nothing and exits 1 when the variable is absent.

Exists because the obvious shell one-liner is wrong in a way that looks right:
the 1Password credentials value is JSON inside an HCL string, so it is full of
escaped quotes, and `"([^"]*)"` stops at the first one and yields a
two-character value. Heredoc-assigned values need handling too.
"""
import json
import re
import sys


def get(path, name):
    s = open(path).read()
    n = re.escape(name)
    m = re.search(r'^%s\s*=\s*"((?:[^"\\]|\\.)*)"' % n, s, re.M)
    if m:
        # HCL string escaping matches JSON's closely enough for these values,
        # and round-tripping through json keeps the unescape and the later
        # re-escape symmetrical.
        return json.loads('"%s"' % m.group(1))
    m = re.search(r'^%s\s*=\s*<<-?([A-Za-z][A-Za-z0-9_]*)\s*\n(.*?)\n\s*\1\s*$' % n, s, re.M | re.S)
    if m:
        return m.group(2)
    return None


def set_(path, name, value):
    try:
        s = open(path).read()
    except FileNotFoundError:
        s = ""
    line = "%s = %s" % (name, json.dumps(value))
    if re.search(r"^%s\s*=" % re.escape(name), s, re.M):
        # Replace the whole assignment, heredoc body included.
        s = re.sub(r'^%s\s*=\s*<<-?([A-Za-z][A-Za-z0-9_]*)\s*\n.*?\n\s*\1\s*$' % re.escape(name),
                   line, s, count=1, flags=re.M | re.S)
        s = re.sub(r"^%s\s*=[^\n]*$" % re.escape(name), line, s, count=1, flags=re.M)
    else:
        s = s.rstrip("\n") + "\n" + line + "\n"
    open(path, "w").write(s.lstrip("\n"))


if __name__ == "__main__":
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    op, path, name = sys.argv[1], sys.argv[2], sys.argv[3]
    if op == "get":
        v = get(path, name)
        if v is None:
            sys.exit(1)
        sys.stdout.write(v)
    elif op == "set":
        set_(path, name, sys.argv[4])
    else:
        sys.exit("unknown op %r" % op)
