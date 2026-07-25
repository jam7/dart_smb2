#!/usr/bin/env python3
"""Stop private data from reaching this public repository.

This library talks to a real file server, so what leaks here is a host, a
share, an account, or a path on someone's NAS -- and it leaks through the
examples that show how to run the integration tests. That is not theoretical:
a real LAN address, share name, user name and file path all sat in this
history until they were scrubbed on 2026-07-25.

Deliberately small. The app repository has a larger version with a vocabulary
for test data, which this does not need: nothing here handles a user's
content, so the whole exposure is a handful of connection details.

Three checks:

* Private IP addresses, other than the one declared below as the example.
* Absolute home directories.
* SMB_* example values -- an allowlist, because the leaked names (`Movies`,
  `jam`) were ordinary words that no denylist would have predicted.

An exact denylist is read from notes/private-patterns.txt, or ../notes/ when
this repository is nested inside the app's working tree. It is optional and
silently skipped when absent -- that file lists real names, so it belongs in a
private repository, never in this one.

Usage:
  check-private.py --staged        what is about to be committed
  check-private.py --range A..B    every revision in a range, and messages
  check-private.py --all-history   every revision that exists
  check-private.py --worktree      the files on disk right now
"""
import argparse
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DENYLIST_FILES = (
    os.path.join(ROOT, 'notes', 'private-patterns.txt'),
    os.path.join(ROOT, os.pardir, 'notes', 'private-patterns.txt'),
)

# The one address examples may use. Chosen from a subnet the developer never
# has on a LAN, so a real address pasted in by accident cannot pass for it.
EXAMPLE_HOST = '192.168.99.100'

# The example before it, invented too but inside the developer's own subnet.
# It is still in the published history and cannot be taken back, so the audit
# accepts it there -- and only there. New content must use EXAMPLE_HOST, which
# is the whole reason the address changed.
HISTORICAL_HOSTS = {'192.168.1.100'}

# Values the SMB_* examples may take. Anything else is assumed to be real:
# `Movies` and `jam` were, and both are words a denylist would never have
# thought to include.
ALLOWED_SMB_VALUES = {
    'SMB_HOST': {EXAMPLE_HOST, 'localhost', '127.0.0.1', '$HOST', '$SMB_HOST'},
    'SMB_SHARE': {'photos', 'share', '$SHARE', '$SMB_SHARE'},
    'SMB_USER': {'user', '$USER', '$SMB_USER'},
    'SMB_PASS': {'pass', 'xxx', '"$PASS"', '$PASS', '$SMB_PASS'},
    'SMB_PORT': {'445', '$PORT', '$SMB_PORT'},
    'SMB_BENCH_FILE': {'photo.png', '"photo.png"', '"path/to/large_file.png"',
                       '$SMB_BENCH_FILE'},
}

PRIVATE_IP = re.compile(
    r'\b(?:192\.168\.\d{1,3}\.\d{1,3}'
    r'|10\.\d{1,3}\.\d{1,3}\.\d{1,3}'
    r'|172\.(?:1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3})\b')
HOME_PATH = re.compile(r'(?<![\w/.])(?:/home/[a-z0-9_.-]+'
                       r'|/Users/[A-Za-z0-9_.-]+'
                       r'|[A-Z]:\\Users\\[A-Za-z0-9_.-]+)')
SMB_ASSIGN = re.compile(r'\b(SMB_[A-Z_]+)=(\S+)')

SCAN_SCOPE = re.compile(r'\.(dart|md|ya?ml|sh|txt)$')


def load_denylist():
    for path in DENYLIST_FILES:
        if not os.path.exists(path):
            continue
        out = []
        with open(path, encoding='utf-8') as f:
            for line in f:
                line = re.sub(r'(?:^|\s)#.*$', '', line).strip()
                if line:
                    out.append(line)
        return out
    return []


def check_content(where, content, denylist, historical=False):
    allowed_hosts = {EXAMPLE_HOST} | (HISTORICAL_HOSTS if historical else set())
    problems = []
    for lineno, line in enumerate(content.split('\n'), 1):
        for m in PRIVATE_IP.finditer(line):
            if m.group(0) not in allowed_hosts:
                problems.append((where, lineno, 'private IP address', m.group(0)))
        m = HOME_PATH.search(line)
        if m:
            problems.append((where, lineno, 'absolute home path', m.group(0)))
        for key, value in SMB_ASSIGN.findall(line):
            allowed = ALLOWED_SMB_VALUES.get(key)
            if key == 'SMB_HOST':
                allowed = (allowed or set()) | allowed_hosts
            if allowed is not None and value not in allowed:
                problems.append((where, lineno,
                                 f'{key} is not one of the example values', value))
        for term in denylist:
            if term.lower() in line.lower():
                problems.append((where, lineno, 'known private name', term))
    return problems


def git(*args):
    return subprocess.run(['git'] + list(args), cwd=ROOT, capture_output=True,
                          text=True, errors='replace').stdout


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument('--staged', action='store_true')
    g.add_argument('--worktree', action='store_true')
    g.add_argument('--range')
    g.add_argument('--all-history', action='store_true')
    args = ap.parse_args()

    denylist = load_denylist()
    problems = []

    if args.staged or args.worktree:
        if args.staged:
            names = git('diff', '--cached', '--name-only',
                        '--diff-filter=ACMR').split('\n')
        else:
            names = git('ls-files').split('\n')
        for path in filter(None, names):
            if not SCAN_SCOPE.search(path):
                continue
            content = git('show', ':' + path) if args.staged else None
            if content is None:
                full = os.path.join(ROOT, path)
                if not os.path.exists(full):
                    continue
                with open(full, encoding='utf-8', errors='replace') as f:
                    content = f.read()
            problems += check_content(path, content, denylist)
    else:
        spec = ['--all'] if args.all_history else [args.range]
        for rev in filter(None, git('rev-list', *spec).split('\n')):
            problems += check_content(rev[:9] + ' (message)',
                                      git('log', '-1', '--format=%B', rev),
                                      denylist, historical=True)
            changed = git('diff-tree', '-r', '--no-commit-id', '--name-only',
                          '--diff-filter=ACMR', rev).split('\n')
            for path in filter(None, changed):
                if not SCAN_SCOPE.search(path):
                    continue
                problems += check_content(f'{rev[:9]} {path}',
                                          git('show', f'{rev}:{path}'), denylist,
                                          historical=True)

    if not problems:
        return 0
    print('Private data check failed:\n', file=sys.stderr)
    for where, lineno, why, hit in problems:
        print(f'  {where}:{lineno}: {why}: {hit}', file=sys.stderr)
    print(f'\n{len(problems)} problem(s).', file=sys.stderr)
    print('Examples use the values in tools/check-private.py; a new one is '
          'added there,', file=sys.stderr)
    print('deliberately, rather than pasted in from a real session.',
          file=sys.stderr)
    return 1


if __name__ == '__main__':
    sys.exit(main())
