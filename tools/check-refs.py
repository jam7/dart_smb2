#!/usr/bin/env python3
"""Flag commit-hash references in tracking documents.

This file is a copy. The original, and the install.sh that placed and
updates it, live in https://github.com/jam7/ai-dev-gates

Written after a history rewrite (removing real data with git filter-repo)
killed all 25 commit hashes in the tracking documents at once -- and nothing
noticed. A dead hash builds, tests and greps fine; it is opaque to review;
and it cannot even be checked for life reliably, because an amended-away
commit stays in the local object store for months, so `git cat-file`
approves references that no clone can resolve.

So the rule is not "no dead hashes" but "no hashes", alive or not
(coding-rules rules/40-references.md): reference a change by its commit
subject, an implementation by file and symbol, and another repository's
change by summarizing it on your own side.

A token is flagged when it is 7-40 characters of hex containing both a
letter and a digit. Dates (20260704) and decimal ids stay quiet; the rare
hash that happens to be all letters or all digits slips through, which the
rule accepts. Hex that belongs in a document (a checksum, an example) is
declared in tools/refs-allow.txt with the reason above it, the same
contract as cq-baseline.txt: writing the entry is the review.

Usage:
  check-refs.py --staged           files about to be committed
  check-refs.py PATH...            these files/directories, right now

  --scope RE    what counts as a tracking document, repeatable
                (default: docs/**.md and any TODO.md)
  --allow PATH  declared exceptions (default tools/refs-allow.txt)

Exit codes: 0 = clean, 1 = references found, 2 = usage error.
"""
import argparse
import os
import re
import subprocess
import sys

DEFAULT_ALLOW = os.path.join('tools', 'refs-allow.txt')
DEFAULT_SCOPE = (r'(^|/)docs/.*\.md$', r'(^|/)TODO\.md$')

HEX_TOKEN = re.compile(r'\b[0-9a-f]{7,40}\b')
HAS_LETTER = re.compile(r'[a-f]')
HAS_DIGIT = re.compile(r'[0-9]')


def repo_root():
    done = subprocess.run(['git', 'rev-parse', '--show-toplevel'],
                          capture_output=True, text=True)
    if done.returncode == 0 and done.stdout.strip():
        return done.stdout.strip()
    return os.getcwd()


def load_allow(path):
    """Tokens declared acceptable, one per line, reason in a comment above."""
    tokens = set()
    if not os.path.exists(path):
        return tokens
    with open(path, encoding='utf-8') as f:
        for line in f:
            line = re.sub(r'(?:^|\s)#.*$', '', line).strip()
            if line:
                tokens.add(line)
    return tokens


def hash_like(token):
    return HAS_LETTER.search(token) and HAS_DIGIT.search(token)


def check_file(path, display, allow):
    problems = []
    try:
        with open(path, encoding='utf-8', errors='replace') as f:
            lines = f.read().splitlines()
    except OSError:
        return problems
    for lineno, line in enumerate(lines, 1):
        for token in HEX_TOKEN.findall(line):
            if hash_like(token) and token not in allow:
                problems.append('%s:%d: commit-hash-like reference: %s'
                                % (display, lineno, token))
    return problems


def staged_files(root, scopes):
    done = subprocess.run(
        ['git', 'diff', '--cached', '--name-only', '--diff-filter=ACMR'],
        cwd=root, capture_output=True, text=True)
    return [(os.path.join(root, p), p) for p in done.stdout.split('\n')
            if p and any(rx.search(p) for rx in scopes)]


def listed_files(paths, scopes):
    """Explicit files are scanned as asked; directories are walked and
    filtered to tracking documents."""
    out = []
    for p in paths:
        if os.path.isfile(p):
            out.append((p, p))
            continue
        for root, dirs, names in os.walk(p):
            dirs[:] = [d for d in dirs if not d.startswith('.')]
            for name in sorted(names):
                full = os.path.join(root, name)
                if any(rx.search(full) for rx in scopes):
                    out.append((full, full))
    return out


def main():
    ap = argparse.ArgumentParser(
        description='Fail on commit-hash references in tracking documents.')
    ap.add_argument('--staged', action='store_true')
    ap.add_argument('--scope', action='append', metavar='RE')
    ap.add_argument('--allow', default=DEFAULT_ALLOW, metavar='PATH')
    ap.add_argument('paths', nargs='*', metavar='PATH')
    args = ap.parse_args()
    if args.staged == bool(args.paths):
        ap.error('give either --staged or paths to scan')

    root = repo_root()
    scopes = tuple(re.compile(p) for p in (args.scope or DEFAULT_SCOPE))
    allow = args.allow if os.path.isabs(args.allow) \
        else os.path.join(root, args.allow)
    allowed = load_allow(allow)

    files = staged_files(root, scopes) if args.staged \
        else listed_files(args.paths, scopes)
    problems = []
    for path, display in files:
        problems += check_file(path, display, allowed)

    if not problems:
        return 0
    report(problems, args.allow)
    return 1


def report(problems, allow_path):
    print('Commit-hash references in tracking documents:\n', file=sys.stderr)
    for p in problems:
        print('  ' + p, file=sys.stderr)
    print('\n%d reference(s).\n' % len(problems), file=sys.stderr)
    print('A hash dies wholesale on any history rewrite and cannot be', file=sys.stderr)
    print('checked for life. Point at the commit subject, or the file and', file=sys.stderr)
    print('symbol, instead (rules/40-references.md). Hex that belongs here', file=sys.stderr)
    print('(a checksum, an example) is declared in %s' % allow_path, file=sys.stderr)
    print('with its reason -- writing the entry is the review.', file=sys.stderr)


if __name__ == '__main__':
    sys.exit(main())
