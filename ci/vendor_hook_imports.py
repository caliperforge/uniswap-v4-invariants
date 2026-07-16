#!/usr/bin/env python3
# vendor_hook_imports.py -- BFS-walk a Solidity file's import graph and
# vendor every project-local (relative-import) sibling into an adopter
# scaffold directory, preserving relative subpath shape so the copied
# files' own relative imports still resolve.
#
# Called by `./caliper run <hook.sol>` (see the wrapper for context).
#
# Usage:  vendor_hook_imports.py <hook_abs> <src_root> <adopter_src_dir>
#   hook_abs        absolute path to the hook .sol file the adopter is running
#   src_root        absolute path of the hook's project source root; relative
#                   imports may not escape this via `../`. Copied files are
#                   placed under adopter_src_dir at the same subpath they had
#                   relative to src_root.
#   adopter_src_dir project-relative directory (the caliper wrapper's
#                   `src/adopters/caliper-run`) where copies land.
#
# Stdout: one `EXTERNAL <prefix>` line per unique package-prefixed import
#         seen (e.g. `EXTERNAL v4-core/`), sorted, deduped. The wrapper
#         echoes these so a reviewer can spot a missing foundry.toml
#         remapping without digging. Package-prefixed imports are NOT
#         copied -- they resolve through Foundry remappings.
#
# Stdlib only (no pip). Regex-based, not a real Solidity parser -- but
# adequate for `import "..."` / `import {X} from "..."` shapes, which is
# what production hook code uses. Multi-line import statements are
# stitched to a single logical line before matching.
#
# Failure surface: exits non-zero if a relative import tries to escape
# src_root (would silently vendor arbitrary paths otherwise), or if a
# sibling file it needs to copy is not on disk.

import os
import re
import shutil
import sys
from collections import deque

# Match both `import "path";` and `import {A, B} from "path";` (and the
# `import * as X from "..."` / `import "..." as X` variants). We only
# care about the path literal; the rest is passed through untouched.
_IMPORT_PATH_RE = re.compile(r"""import\s+(?:[^"';]*?\bfrom\s+)?["']([^"']+)["']""")


def _stitch_multiline(source: str) -> str:
    # Collapse multi-line import statements to a single logical line so
    # the regex above matches them. We only touch statements starting
    # with `import` at the beginning of a line (allowing whitespace).
    out = []
    buf = None
    for line in source.splitlines():
        stripped = line.lstrip()
        if buf is not None:
            buf += " " + line
            if ";" in line:
                out.append(buf)
                buf = None
            continue
        if stripped.startswith("import") and ";" not in line:
            buf = line
        else:
            out.append(line)
    if buf is not None:
        out.append(buf)
    return "\n".join(out)


def _extract_imports(source: str):
    stitched = _stitch_multiline(source)
    return _IMPORT_PATH_RE.findall(stitched)


def _resolve_relative(base_file: str, rel: str, src_root: str) -> str:
    # base_file is an absolute path to the file that contains the import;
    # rel is a path starting with `./` or `../`. Return the absolute
    # resolved path, guarding against escaping src_root.
    base_dir = os.path.dirname(base_file)
    resolved = os.path.normpath(os.path.join(base_dir, rel))
    if not resolved.startswith(src_root + os.sep) and resolved != src_root:
        raise ValueError(
            f"relative import '{rel}' from '{base_file}' escapes CALIPER_HOOK_SRC_ROOT "
            f"({src_root}); resolved to '{resolved}'. Set CALIPER_HOOK_SRC_ROOT to a "
            f"broader directory (e.g. the hook repo's top-level src/) so the walker "
            f"can reach every sibling the hook actually imports."
        )
    return resolved


def main(argv):
    if len(argv) != 4:
        print("usage: vendor_hook_imports.py <hook_abs> <src_root> <adopter_src_dir>",
              file=sys.stderr)
        return 2
    hook_abs = os.path.abspath(argv[1])
    src_root = os.path.abspath(argv[2]).rstrip(os.sep)
    adopter_dir = os.path.abspath(argv[3])

    if not os.path.isfile(hook_abs):
        print(f"vendor_hook_imports: hook file not found: {hook_abs}", file=sys.stderr)
        return 3
    if not os.path.isdir(src_root):
        print(f"vendor_hook_imports: src_root not a directory: {src_root}", file=sys.stderr)
        return 3
    if not hook_abs.startswith(src_root + os.sep):
        print(f"vendor_hook_imports: hook_abs '{hook_abs}' is not under src_root "
              f"'{src_root}'. Set CALIPER_HOOK_SRC_ROOT to a directory that contains "
              f"the hook.", file=sys.stderr)
        return 3

    os.makedirs(adopter_dir, exist_ok=True)

    seen_files = set()
    externals = set()
    queue = deque([hook_abs])

    while queue:
        current = queue.popleft()
        if current in seen_files:
            continue
        if not os.path.isfile(current):
            print(f"vendor_hook_imports: expected sibling not on disk: {current}",
                  file=sys.stderr)
            return 4
        seen_files.add(current)

        # Copy current -> adopter_dir/<same subpath under src_root>
        rel_from_root = os.path.relpath(current, src_root)
        dest = os.path.join(adopter_dir, rel_from_root)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        shutil.copy2(current, dest)

        with open(current, "r", encoding="utf-8") as f:
            source = f.read()

        for imp in _extract_imports(source):
            if imp.startswith("./") or imp.startswith("../"):
                try:
                    resolved = _resolve_relative(current, imp, src_root)
                except ValueError as e:
                    print(f"vendor_hook_imports: {e}", file=sys.stderr)
                    return 5
                queue.append(resolved)
            else:
                # Package-prefixed import -- surface the top-level
                # prefix so the wrapper's diagnostic can print it.
                # Prefix definition: everything up to and including the
                # first `/` (e.g. `@openzeppelin/contracts/...` -> the
                # prefix a foundry.toml remapping would key on is
                # `@openzeppelin/`, but adopters more often think in
                # terms of the full package root -- take up to the
                # SECOND `/` if the first segment is a `@scope`, else
                # up to the first `/`).
                if imp.startswith("@") and imp.count("/") >= 1:
                    # e.g. `@openzeppelin/contracts/foo.sol` -> `@openzeppelin/contracts/`
                    parts = imp.split("/", 2)
                    prefix = parts[0] + "/" + parts[1] + "/"
                else:
                    prefix = imp.split("/", 1)[0] + "/"
                externals.add(prefix)

    for prefix in sorted(externals):
        print(f"EXTERNAL {prefix}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
