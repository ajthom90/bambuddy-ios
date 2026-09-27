#!/usr/bin/env python3
"""Inspect the Bambuddy OpenAPI snapshot (docs/api/openapi.json).

  scripts/schema.py p <path-prefix> [...]   list endpoints under /api/v1/<prefix>
  scripts/schema.py s <SchemaName> [...]    show a schema's fields ('?' = optional)
"""
import json, os, sys

SPEC = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "docs", "api", "openapi.json")
d = json.load(open(SPEC))
S = d["components"]["schemas"]


def t(p):
    if "$ref" in p:
        return p["$ref"].split("/")[-1]
    if "anyOf" in p:
        return "|".join(t(x) for x in p["anyOf"])
    if p.get("type") == "array":
        return "[" + t(p.get("items", {})) + "]"
    if p.get("type") == "object" and "additionalProperties" in p:
        ap = p["additionalProperties"]
        return "{str:" + (t(ap) if isinstance(ap, dict) else "any") + "}"
    if "enum" in p:
        return "enum" + str(p["enum"])
    return p.get("type", "any") + ("(" + p["format"] + ")" if "format" in p else "")


def show(n):
    s = S[n]
    req = set(s.get("required", []))
    print(f"## {n}")
    for k, v in s.get("properties", {}).items():
        print(f"  {k}{'' if k in req else '?'}: {t(v)}")


if __name__ == "__main__":
    if len(sys.argv) < 3 or sys.argv[1] not in ("p", "s"):
        print(__doc__)
        sys.exit(1)
    if sys.argv[1] == "s":
        for n in sys.argv[2:]:
            show(n)
    else:
        for k, v in d["paths"].items():
            if any(k.startswith("/api/v1/" + a) for a in sys.argv[2:]):
                for m, o in v.items():
                    rb = o.get("requestBody", {}).get("content", {})
                    body = ",".join(f"{ct.split('/')[-1]}:{t(c.get('schema', {}))}" for ct, c in rb.items())
                    resp = o.get("responses", {}).get("200", {}).get("content", {}).get("application/json", {}).get("schema", {})
                    qs = ",".join(p["name"] + ("" if p.get("required") else "?") for p in o.get("parameters", []) if p["in"] == "query")
                    print(f"{m.upper():6} {k}{' ?' + qs if qs else ''}{' BODY ' + body if body else ''} -> {t(resp) if resp else '-'}")
