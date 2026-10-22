#!/usr/bin/env python3
"""Check tracked content and reachable commit metadata before sharing a repository.

This complements a secret scanner; it cannot identify every kind of private information.
"""
import pathlib
import re
import subprocess
import sys

EMAIL = re.compile(r"[A-Za-z0-9_.+%-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")
HOME_PATH = re.compile(r"/Users" + r"/([^/\s\"']+)")
DEVELOPMENT_MODEL = re.compile(r"\b(?:Claude|GPT|Gemini|Llama)[ -]+(?:\d[\w.-]*|[A-Z][a-z]+[ -]+\d[\w.-]*)", re.I)
FORBIDDEN_SUFFIXES = {".wav", ".m4a", ".mp3", ".mov", ".mp4", ".pem", ".key", ".p12", ".pfx"}


def issues_in_text(text):
    found = []
    for address in EMAIL.findall(text):
        domain = address.rsplit("@", 1)[1].lower()
        if domain != "example.com" and not domain.endswith("users.noreply.github.com"):
            found.append("non-placeholder email address")
    for match in HOME_PATH.finditer(text):
        if match.group(1) not in {"x", "you", "…"}:
            found.append("personal absolute home path")
    if DEVELOPMENT_MODEL.search(text):
        found.append("specific development model label")
    return sorted(set(found))


def git(root, *args):
    return subprocess.check_output(["git", "-C", str(root), *args])


def check(root):
    failures = []
    files = git(root, "ls-files", "-z").decode().split("\0")
    for name in filter(None, files):
        path = root / name
        if path.suffix.lower() in FORBIDDEN_SUFFIXES or path.name.startswith(".env") and path.name != ".env.example":
            failures.append(f"{name}: recording or credential-like file")
        if path.is_file():
            data = path.read_bytes()
            if b"\0" not in data:
                failures.extend(f"{name}: {issue}" for issue in issues_in_text(data.decode("utf-8", errors="replace")))
    # A later cleanup commit does not hide previous author addresses or trailers.
    metadata = git(root, "log", "--all", "--format=%h%x09%an <%ae> %cn <%ce>%n%B").decode()
    failures.extend(f"commit metadata: {issue}" for issue in issues_in_text(metadata))
    return sorted(set(failures))


def main():
    root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
    failures = check(root)
    if failures:
        print("Publication checks failed (values omitted):", file=sys.stderr)
        print("\n".join(failures), file=sys.stderr)
        return 1
    print("Publication checks passed for tracked content and reachable commit metadata.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
