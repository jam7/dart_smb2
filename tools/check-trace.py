#!/usr/bin/env python3
"""Keep the trace matrix green at commit time.

This file is a copy. The original, and the install.sh that placed and
updates it, live in https://github.com/jam7/ai-dev-gates

The matrix (docs <-> code/tests coherence) is checked at spec-dev gates, but
what breaks it is the work in between: a bug fix deletes a test carrying a
T-ID, a rename severs an S reference. The report then surfaces at the next
gate -- as far from the cause as possible. This runs trace-matrix.py from
pre-commit instead, so the commit that breaks the matrix is the one that
gets told.

The scan is always the full declared scope (every feature, every --code
dir): the invariant is relational -- deleting a test here breaks an S
defined over there -- and a full pass costs well under a second. What is
conditional is the trigger: with --gate, the run is skipped entirely unless
a staged file lies under one of the watched paths (the doc dirs and --code
dirs named in the arguments), so unrelated commits stay instant. On
success it prints nothing.

Usage:
  check-trace.py [--gate] <trace-matrix.py arguments...>
  check-trace.py --gate --code lib --code test docs/     (from pre-commit)

Exit codes are trace-matrix.py's own (0 clean, 1 problems), plus 0 when
--gate finds nothing relevant staged, and 0 with a note when the skill is
not installed -- someone else's commit is not the place to complain.
"""
import os
import subprocess
import sys

METRICS_ENV = 'TRACE_MATRIX'
SKILL_REL = os.path.join('.claude', 'skills', 'spec-dev', 'trace-matrix.py')


def repo_root():
    done = subprocess.run(['git', 'rev-parse', '--show-toplevel'],
                          capture_output=True, text=True)
    if done.returncode == 0 and done.stdout.strip():
        return done.stdout.strip()
    return os.getcwd()


def matrix_script(root):
    """trace-matrix.py from the repo install, the home install, or $TRACE_MATRIX."""
    for candidate in (os.environ.get(METRICS_ENV),
                      os.path.join(root, SKILL_REL),
                      os.path.expanduser(os.path.join('~', SKILL_REL))):
        if candidate and os.path.isfile(candidate):
            return candidate
    return None


def watched_paths(args):
    """The paths whose change can move the matrix: --code values and the
    positional document paths."""
    watched, take_next = [], False
    for arg in args:
        if take_next:
            watched.append(arg)
            take_next = False
        elif arg == '--code':
            take_next = True
        elif not arg.startswith('-'):
            watched.append(arg)
    return [os.path.normpath(w) for w in watched]


def staged_touches(root, watched):
    done = subprocess.run(['git', 'diff', '--cached', '--name-only'],
                          cwd=root, capture_output=True, text=True)
    for path in filter(None, done.stdout.split('\n')):
        norm = os.path.normpath(path)
        for w in watched:
            if norm == w or norm.startswith(w + os.sep):
                return True
    return False


def main():
    args = sys.argv[1:]
    gate = '--gate' in args
    if gate:
        args = [a for a in args if a != '--gate']
    if not args:
        print('usage: check-trace.py [--gate] <trace-matrix.py arguments>',
              file=sys.stderr)
        return 2

    root = repo_root()
    script = matrix_script(root)
    if script is None:
        print('trace-matrix.py not found (%s); skipping the trace check.'
              % SKILL_REL, file=sys.stderr)
        print('Set %s to point at it.' % METRICS_ENV, file=sys.stderr)
        return 0
    if gate and not staged_touches(root, watched_paths(args)):
        return 0

    done = subprocess.run([sys.executable, script] + args, cwd=root,
                          capture_output=True, text=True)
    if done.returncode != 0 or not gate:
        sys.stdout.write(done.stdout)
        sys.stderr.write(done.stderr)
    return done.returncode


if __name__ == '__main__':
    sys.exit(main())
