#!/usr/bin/env python3
"""Run textlint over the prose a commit touches, where textlint exists.

This file is a copy. The original, and the install.sh that placed and
updates it, live in https://github.com/jam7/ai-dev-gates

The other checkers are standard-library Python: copy them anywhere and they
run with the same strength. This one needs an outside runtime (Node and
textlint), so its contract differs -- it runs where textlint is installed and
skips with a notice where it is not. The gate is therefore weaker on some
machines, which is only acceptable because what it checks is writing quality.
Anything protective -- private data, dead references -- belongs in the
standard-library layer, where no machine can skip it.

Engine and declarations are split the same way cq-metrics is: the engine
(textlint and its rule packages) belongs to the environment and is installed
with npm; the declarations (what to check, what is allowed) belong to the
repository, under tools/textlint/. Keeping the configuration out of the
repository root is deliberate -- an editor plugin discovers a root
.textlintrc by itself, and would then report our rules as missing to everyone
who clones the repository without installing them.

Usage:
  check-text.py --staged            the prose about to be committed
  check-text.py --worktree          every tracked prose file
  check-text.py FILE...             the named files

  --config PATH    textlint configuration (default below)
  --scope RE       what counts as prose, repeatable (default \\.md$)
  --textlint PATH  the executable, overriding $TEXTLINT and the PATH lookup

Like check-metrics, this measures the working tree rather than the index,
because textlint reads files from disk: a half-staged file is checked as it
will be after the commit, not as it is being committed.

Exit codes are textlint's own (0 clean, 1 findings), plus 0 when nothing in
scope changed or textlint is not installed, and 2 when textlint is installed
but the configuration is missing -- that is this project's own mistake, and
a check that cannot run has to say so rather than pass quietly.
"""
import argparse
import os
import re
import shutil
import subprocess
import sys

TEXTLINT_ENV = 'TEXTLINT'
DEFAULT_CONFIG = os.path.join('tools', 'textlint', 'textlintrc.yml')
DEFAULT_SCOPE = (r'\.md$',)
LOCAL_BIN = os.path.join('node_modules', '.bin', 'textlint')


def repo_root():
    """The repository being checked, or the current directory."""
    done = subprocess.run(['git', 'rev-parse', '--show-toplevel'],
                          capture_output=True, text=True)
    if done.returncode == 0 and done.stdout.strip():
        return done.stdout.strip()
    return os.getcwd()


def git(root, *args):
    return subprocess.run(['git'] + list(args), cwd=root, capture_output=True,
                          text=True, errors='replace').stdout


def textlint_program(root, override):
    """The textlint to run, or None when there is none.

    A named one (--textlint, $TEXTLINT) is the whole answer: falling back to
    the PATH when the named path is wrong would hide the typo behind a
    different binary. Otherwise a project-local install wins over the PATH,
    so a repository that pins its own textlint gets the pinned one.
    """
    named = override or os.environ.get(TEXTLINT_ENV)
    if named:
        return named if os.path.isfile(named) else None
    local = os.path.join(root, LOCAL_BIN)
    return local if os.path.isfile(local) else shutil.which('textlint')


def prose_files(root, args):
    """The files to check: named, staged, or every tracked one -- filtered to
    the prose scope, and to what is actually on disk (textlint reads disk)."""
    if args.paths:
        names = args.paths
    elif args.staged:
        names = git(root, 'diff', '--cached', '--name-only',
                    '--diff-filter=ACMR').split('\n')
    else:
        names = git(root, 'ls-files').split('\n')
    scope = [re.compile(p) for p in (args.scope or DEFAULT_SCOPE)]
    return [n for n in filter(None, names)
            if any(p.search(n) for p in scope)
            and os.path.isfile(os.path.join(root, n))]


def report_missing_textlint():
    """Not an error: a machine without Node is not a broken machine, and
    someone else's commit is not the place to argue about it. It is still
    said out loud, so that a skipped check is never read as a passed one."""
    print('textlint not found; skipping the text check.', file=sys.stderr)
    print('Install it (npm install -g textlint <rule packages>), or set %s '
          'to its path.' % TEXTLINT_ENV, file=sys.stderr)


def report_missing_config(config):
    print('error: textlint is installed but %s is missing.' % config,
          file=sys.stderr)
    print('Create it (tools/textlint/*.template.* are the starting points), '
          'or clear', file=sys.stderr)
    print('text_scope in tools/gate.conf. A check that cannot run must not '
          'pass quietly.', file=sys.stderr)


def parse_args():
    ap = argparse.ArgumentParser(
        description='Run textlint over prose files, where textlint exists.')
    group = ap.add_mutually_exclusive_group()
    group.add_argument('--staged', action='store_true',
                       help='the prose about to be committed')
    group.add_argument('--worktree', action='store_true',
                       help='every tracked prose file')
    ap.add_argument('paths', nargs='*', metavar='FILE')
    ap.add_argument('--config', default=DEFAULT_CONFIG, metavar='PATH',
                    help='textlint configuration (default: %s)' % DEFAULT_CONFIG)
    ap.add_argument('--scope', action='append', metavar='RE',
                    help='what counts as prose, repeatable (default: \\.md$)')
    ap.add_argument('--textlint', metavar='PATH', help='the executable to run')
    args = ap.parse_args()
    if not (args.staged or args.worktree or args.paths):
        ap.error('one of --staged, --worktree or a file path is required')
    return args


def main():
    args = parse_args()
    root = repo_root()

    # Nothing in scope: say nothing at all, so that commits touching no prose
    # stay silent whether or not this machine could have checked them.
    files = prose_files(root, args)
    if not files:
        return 0

    program = textlint_program(root, args.textlint)
    if program is None:
        report_missing_textlint()
        return 0
    if not os.path.exists(os.path.join(root, args.config)):
        report_missing_config(args.config)
        return 2

    done = subprocess.run([program, '--config', args.config] + files, cwd=root)
    return done.returncode


if __name__ == '__main__':
    sys.exit(main())
