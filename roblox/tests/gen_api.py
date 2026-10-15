"""Builds api.luau (Roblox classes, properties, methods and enums) from the @rbxts/types
package, so api_test.luau can reject any property, method or Enum that Roblox doesn't have.

Usage (from this folder): python3 gen_api.py path/to/package/include/generated
"""
import re
import sys

generated = sys.argv[1] if len(sys.argv) > 1 else "rbxts/package/include/generated"
src = open(generated + "/None.d.ts").read()
out = ["return {classes = {"]
pattern = r"^interface (\w+)(?:<[^{]*?>)?(?: extends ([\w, ]+?)(?:<[^{]*?>)?)? \{\n(.*?)^\}"
for m in re.finditer(pattern, src, re.M | re.S):
    name, ext, body = m.group(1), m.group(2), m.group(3)
    props, methods = {}, set()
    for line in body.split("\n"):
        l = line.strip()
        if l.startswith("*") or l.startswith("/"):
            continue
        mm = re.match(r"(readonly )?(\w+)\s*:\s*(.+);$", l)
        if mm:
            t = mm.group(3)
            if "RBXScriptSignal" in t:
                kind = "signal"
            elif t.startswith("number"):
                kind = "number"
            elif t.startswith("boolean"):
                kind = "boolean"
            elif t.startswith("string"):
                kind = "string"
            elif t.startswith("Vector3"):
                kind = "Vector3"
            elif t.startswith("CFrame"):
                kind = "CFrame"
            elif t.startswith("Enum."):
                kind = "enum"
            else:
                kind = "other"
            props[mm.group(2)] = (kind, "true" if mm.group(1) else "false")
            continue
        mm = re.match(r"(\w+)(?:<[^>]*>)?\(this", l)
        if mm:
            methods.add(mm.group(1))
    exts = ", ".join('"%s"' % e.strip() for e in ext.split(",")) if ext else ""
    p = ", ".join('%s = {"%s", %s}' % (k, v[0], v[1]) for k, v in props.items() if re.match(r"^[A-Za-z_]\w*$", k))
    me = ", ".join("%s = true" % k for k in sorted(methods))
    out.append("  %s = {ext = {%s}, props = {%s}, methods = {%s}}," % (name, exts, p, me))

out.append("}, enums = {")
enums, current = {}, None
for line in open(generated + "/enums.d.ts").read().split("\n"):
    m = re.match(r"\s*export namespace (\w+) \{", line)
    if m:
        current = m.group(1)
        enums.setdefault(current, {})
        continue
    m = re.match(r"\s*export interface (\w+) extends globalThis\.EnumItem", line)
    if m and current:
        enums[current][m.group(1)] = None
        continue
    m = re.match(r"\s*Value: (-?\d+);", line)
    if m and current and enums[current]:
        last = list(enums[current].keys())[-1]
        if enums[current][last] is None:
            enums[current][last] = int(m.group(1))
for k, v in enums.items():
    items = ", ".join("%s = %d" % (a, b if b is not None else 0) for a, b in v.items() if re.match(r"^[A-Za-z_]\w*$", a))
    out.append("  %s = {%s}," % (k, items))
out.append("}}")
open("api.luau", "w").write("\n".join(out))
print("wrote api.luau")
