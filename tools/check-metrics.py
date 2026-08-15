#!/usr/bin/env python3
"""Stop new structural flags from being committed without being declared.

This file is a copy. The original, and the install.sh that placed and
updates it, live in https://github.com/jam7/ai-dev-gates

cq-metrics.py finds long functions, deep nesting, long parameter lists and
duplicated blocks. Some of what it finds is deliberate -- a byte-for-byte
protocol builder is worth more laid out beside the spec than split up -- so a
plain threshold cannot be a gate.

So the gate is a **declaration**: every accepted flag is a line in the
baseline file with the reason it is accepted. Anything cq-metrics reports that
is not in that file fails the commit, **by name**. Accepting a new one means
adding a line and saying why, and writing that line is the review.

It also reports baseline entries that no longer appear. Those are decisions
being defended for code that has changed shape, and they go stale quietly.
"No longer appears" has two very different causes, and they are reported
apart: a function that measures under the threshold now is an improvement,
but a function the analyzer cannot find at all may be a parser gap -- and
advising "remove the line" for those once deleted a live 73-line
declaration when a wrapped Dart signature stopped being parsed.

Keys ignore line numbers, since those shift under every edit:

    long <path>::<function>     (also deep, params)
    dup  <path-a>|<path-b>      (the pair, so a second distinct duplicate
                                 between the same two files is not caught)

Usage:
  check-metrics.py                     measure, compare, report
  check-metrics.py --list              print the current keys, to seed the baseline
  check-metrics.py --scope lib --ext .dart
"""
import argparse
import os
import re
import subprocess
import sys

DEFAULT_BASELINE = os.path.join('tools', 'cq-baseline.txt')
# cq-metrics.py lives in the cq-review skill, which may be installed in the
# repository (team install) or in the home directory (personal install).
METRICS_ENV = 'CQ_METRICS'
SKILL_REL = os.path.join('.claude', 'skills', 'cq-review', 'cq-metrics.py')

SECTION = re.compile(r'^== (Long functions|Deep nesting|Long parameter lists|'
                     r'Duplicated blocks)')
CATEGORY = {
    'Long functions': 'long',
    'Deep nesting': 'deep',
    'Long parameter lists': 'params',
    'Duplicated blocks': 'dup',
}
FINDING = re.compile(r'^\s+(\S+):(\d+)\s+(\S+?)\(\)')
DUP_SITES = re.compile(r'sites:\s*(.+)$')


def repo_root():
    """The repository being checked, or the directory holding this script."""
    done = subprocess.run(['git', 'rev-parse', '--show-toplevel'],
                          capture_output=True, text=True)
    if done.returncode == 0 and done.stdout.strip():
        return done.stdout.strip()
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def metrics_script(root):
    """Where cq-metrics.py is, or None if it is not installed."""
    for path in (os.environ.get(METRICS_ENV),
                 os.path.join(root, SKILL_REL),
                 os.path.expanduser(os.path.join('~', SKILL_REL))):
        if path and os.path.exists(path):
            return path
    return None


def parse_keys(report):
    """Turn a cq-metrics report into {key: the line it came from}."""
    keys, category = {}, None
    for line in report.split('\n'):
        header = SECTION.match(line)
        if header:
            category = CATEGORY[header.group(1)]
            continue
        if line.startswith('== ') or not line.strip() or category is None:
            continue
        if category == 'dup':
            sites = DUP_SITES.search(line)
            if sites:
                files = sorted({s.strip().rsplit(':', 1)[0]
                                for s in sites.group(1).split(',')})
                keys['dup ' + '|'.join(files)] = line.strip()
            continue
        found = FINDING.match(line)
        if found:
            keys['%s %s::%s' % (category, found.group(1), found.group(3))] = \
                line.strip()
    return keys


def measure(script, root, scopes, ext):
    """Run cq-metrics over the working tree. Returns keys, or None if the
    configured scope does not exist here yet."""
    paths = [p for p in scopes if os.path.isdir(os.path.join(root, p))]
    if not paths:
        return None
    cmd = [sys.executable, script, '--top', '500']
    if ext:
        cmd += ['--ext', ext]
    done = subprocess.run(cmd + paths, cwd=root, capture_output=True,
                          text=True, check=True)
    return parse_keys(done.stdout)


def functions_seen(script, root, paths):
    """Every path::function the analyzer finds in [paths], flagged or not.

    Thresholds at their minimum turn the run into an inventory: the deep and
    params sections list every function, including empty ones.
    """
    cmd = [sys.executable, script, '--max-func-lines', '0', '--max-nest', '-1',
           '--max-params', '-1', '--dup-window', '0', '--top', '100000']
    done = subprocess.run(cmd + paths, cwd=root, capture_output=True,
                          text=True, check=True)
    return {key.split(' ', 1)[1] for key in parse_keys(done.stdout)}


def split_gone(gone, script, root):
    """Split stale keys into (resolved, unseen).

    A resolved flag names a function the analyzer still sees, so measuring
    under the threshold is a real improvement. An unseen one means the
    function itself was not found: a deletion, a rename, or a parser gap --
    the report must not present those as improvements. A key whose file is
    gone is resolved (the code is gone with it), and dup keys name file
    pairs, not functions, so they cannot be told apart and stay resolved.
    """
    targets, resolved = {}, []
    for key in gone:
        category, _, ref = key.partition(' ')
        if category in ('long', 'deep', 'params') and '::' in ref \
                and os.path.isfile(os.path.join(root, ref.split('::', 1)[0])):
            targets.setdefault(ref.split('::', 1)[0], []).append(key)
        else:
            resolved.append(key)
    if not targets:
        return sorted(resolved), []
    seen = functions_seen(script, root, sorted(targets))
    unseen = [key for keys in targets.values() for key in keys
              if key.split(' ', 1)[1] not in seen]
    resolved += [key for keys in targets.values() for key in keys
                 if key.split(' ', 1)[1] in seen]
    return sorted(resolved), sorted(unseen)


def baseline_keys(path):
    if not os.path.exists(path):
        return set()
    keys = set()
    with open(path, encoding='utf-8') as f:
        for line in f:
            line = line.split('#', 1)[0].strip()
            if line:
                keys.add(line)
    return keys


def report(current, resolved, unseen, new, baseline_name):
    """Print what is undeclared and what is stale. Returns the exit status."""
    if resolved:
        print('No longer flagged -- remove these from %s:' % baseline_name,
              file=sys.stderr)
        for key in resolved:
            print('  %s' % key, file=sys.stderr)
        print(file=sys.stderr)

    if unseen:
        print('Declared, but the function itself is not seen by the '
              'analyzer:', file=sys.stderr)
        for key in unseen:
            print('  %s' % key, file=sys.stderr)
        print('If it was deleted or renamed, remove the line from %s. If the '
              'code is still\nthere, this is a measurement gap, not an '
              'improvement: keep the line and report\nthe parser miss.'
              % baseline_name, file=sys.stderr)
        print(file=sys.stderr)

    if not new:
        return 0

    print('Undeclared structural findings:', file=sys.stderr)
    for key in new:
        print('  %s' % current[key], file=sys.stderr)
    print(file=sys.stderr)
    print('Either restructure, or add the key to %s with the reason it is '
          'worth keeping.' % baseline_name, file=sys.stderr)
    print('The keys are:', file=sys.stderr)
    for key in new:
        print('  %s' % key, file=sys.stderr)
    return 1


def parse_args():
    ap = argparse.ArgumentParser(
        description='Fail on structural findings that are not declared.')
    ap.add_argument('--list', action='store_true',
                    help='print current keys, to seed the baseline')
    ap.add_argument('--scope', action='append', metavar='DIR',
                    help='directory to measure, repeatable (default: the '
                         'whole repository)')
    ap.add_argument('--ext', metavar='.a,.b',
                    help='extensions to measure, passed to cq-metrics.py')
    ap.add_argument('--baseline', metavar='PATH', default=DEFAULT_BASELINE,
                    help='declaration file (default: %s)' % DEFAULT_BASELINE)
    return ap.parse_args()


def main():
    args = parse_args()
    root = repo_root()

    script = metrics_script(root)
    if script is None:
        # Without cq-metrics.py there is nothing to measure, and someone
        # else's commit is not the place to complain about that.
        print('cq-metrics.py not found in %s or ~/%s; skipping the structure '
              'check.' % (root, SKILL_REL), file=sys.stderr)
        print('Set %s to point at it.' % METRICS_ENV, file=sys.stderr)
        return 0

    current = measure(script, root, args.scope or ['.'], args.ext)
    if current is None:
        print('none of the measured directories (%s) exist here; skipping the '
              'structure check.' % ', '.join(args.scope), file=sys.stderr)
        return 0

    if args.list:
        for key in sorted(current):
            print(key)
        return 0

    baseline = args.baseline
    if not os.path.isabs(baseline):
        baseline = os.path.join(root, baseline)
    declared = baseline_keys(baseline)
    resolved, unseen = split_gone(
        sorted(k for k in declared if k not in current), script, root)
    new = sorted(k for k in current if k not in declared)
    return report(current, resolved, unseen, new, args.baseline)


if __name__ == '__main__':
    sys.exit(main())
