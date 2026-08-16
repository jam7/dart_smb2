#!/usr/bin/env python3
"""Stop private data from reaching a repository it must not reach.

This file is a copy. The original, and the install.sh that placed and
updates it, live in https://github.com/jam7/ai-dev-gates

Written for a public repository whose developer's real data (share layout,
work titles, server ids) is not public. Rules in CLAUDE.md were not enough --
real paths leaked several times, in separate sessions, because test data gets
written by copying whatever was on screen in a log. This turns the rule into a
gate that does not depend on anyone remembering it.

Two kinds of check:

* Structural -- absolute home paths, private IPs, long numeric ids. These
  patterns are wrong wherever they appear, so every scanned file gets them.

* Vocabulary (the important one) -- in test data and documentation examples,
  anything that looks like content (a path with separators, a media filename,
  any CJK text) must be built from the vocabulary file. A denylist can only
  catch names someone thought to list; a vocabulary catches the name nobody
  knew about, which is exactly the case that keeps happening.

  The vocabulary check runs only when the vocabulary file exists. Without it
  every invented path would fail, so a project that has not written one yet
  gets the structural checks and nothing else.

An optional denylist is read from notes/private-patterns.txt when that
file exists. It lists real names, so it belongs in a private notes repository
and never in the checked one -- a list of things that must not leak is itself
the worst thing to leak. Terms match with character-class boundaries rather
than as bare substrings: an ASCII term never touches other alphanumerics (an
id inside a longer number is a different value), and a CJK term of one or two
characters matches only next to a delimiter -- CJK prose has no word breaks,
and a bare-substring rule made short names unlistable, which left them
unprotected. Longer CJK terms are distinctive enough to match anywhere.

Deliberate exceptions are declared in tools/private-allow.txt (see --allow),
with the reason above each entry, the same shape as cq-baseline.txt. A plain
token is accepted everywhere (a protocol constant, the one address examples
use); `historical: TOKEN` is accepted only when scanning existing revisions,
for data that published history keeps but new content must not use; and
`key: NAME = V1 V2 ...` restricts what assignments to NAME may say, for
KEY=value examples whose leaked values are ordinary words no denylist would
predict. The denylist is never silenced by this file. The allow file itself
is the one file never scanned -- a historical: entry is by definition a
token new content must not contain, so scanning it would block the act of
declaring. The vocabulary and an (accidentally committed) denylist stay
scanned: a real name pasted into either is exactly what must be caught.

Usage:
  check-private.py --staged            what is about to be committed
  check-private.py --range A..B        every revision in a range, and messages
  check-private.py --all-history       every revision that exists
  check-private.py --worktree          the files on disk right now

  --vocabulary PATH   default tools/test-vocabulary.txt
  --denylist PATH     default notes/private-patterns.txt
  --allow PATH        default tools/private-allow.txt
                      A named path that does not exist is an error (exit 2):
                      it decides what the scan can see, and a run that
                      silently checks nothing must not pass. An absent
                      default is normal, and a readable empty file
                      (--denylist /dev/null) is a deliberate "none".
  --data-scope RE     files whose data must use the vocabulary, repeatable
  --scan-scope RE     files scanned at all (defaults to the data scope plus
                      lib/ and src/), repeatable
"""
import argparse
import os
import re
import subprocess
import sys

DEFAULT_VOCAB = os.path.join('tools', 'test-vocabulary.txt')
DEFAULT_DENYLIST = os.path.join('notes', 'private-patterns.txt')
DEFAULT_ALLOW = os.path.join('tools', 'private-allow.txt')

SOURCE_EXT = (r'\.(dart|py|js|jsx|ts|tsx|go|java|kt|rs|c|cc|cpp|cxx|h|hpp|'
              r'swift|rb|php|cs|scala|m|mm)$')
# Files whose string literals and code examples must use the vocabulary.
DEFAULT_DATA_SCOPE = (
    r'(^|/)tests?/.*' + SOURCE_EXT,
    r'(^|/)docs?/.*\.md$',
    r'^[^/]*\.md$',
)
# Everything scanned at all. Production code is here for the structural checks
# only: its localized UI strings are legitimate content, not test data.
DEFAULT_SCAN_SCOPE = DEFAULT_DATA_SCOPE + (
    r'(^|/)(lib|src)/.*' + SOURCE_EXT,
)

CJK_RANGE = r'぀-ヿ㐀-䶿一-鿿'
CJK = re.compile('[%s]' % CJK_RANGE)
# `$e\n$st` in a logging example is one string, not a two-segment path. A real
# path carries a dot, a slash or a drive colon; an escape sequence does not.
ESCAPE_NOT_PATH = re.compile(r'^[^/:.]*\\[nrt0v][^/:.]*$')
MEDIA = re.compile(r'\.(pdf|zip|cbz|rar|jpe?g|png|gif|webp|mp4|mkv|avi|webm'
                   r'|mov|wmv|ts|m4v)$', re.I)

STRUCTURAL = [
    # Case-sensitive on purpose: `/Home/End` is a pair of keys and
    # `pixiv.net/users/123` is a URL, and both matched when it was not.
    #
    # The user name has to start with a letter, digit or underscore. Writing
    # `/home/...` in documentation is how you say "somebody's home", and it is
    # not a leak; a name beginning with a dot or a dash is not a user either.
    # Anything after the first character may be a dot, so /home/j.doe still
    # matches.
    (re.compile(r'(?<![\w/.])/home/[a-z0-9_][a-z0-9_.-]*'), 'absolute home path'),
    (re.compile(r'(?<![\w/.])/Users/[A-Za-z0-9_][A-Za-z0-9_.-]*'),
     'absolute home path'),
    (re.compile(r'[A-Z]:\\\\?Users\\\\?[a-z0-9_][a-z0-9_.-]*', re.I),
     'absolute home path'),
    (re.compile(r'\b192\.168\.\d{1,3}\.\d{1,3}\b'), 'private IP address'),
    (re.compile(r'\b10\.\d{1,3}\.\d{1,3}\.\d{1,3}\b'), 'private IP address'),
    (re.compile(r'\b172\.(1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3}\b'), 'private IP address'),
    (re.compile(r'(?<![\d.])\d{12,}(?![\d.])'), 'long numeric id'),
]

# KEY=value assignments, for the keyed example-value check. Only keys declared
# in the allow file are checked, so the generic shape costs nothing.
KEY_ASSIGN = re.compile(r'\b([A-Z][A-Z0-9_]{2,})=(\S+)')

# String literals are pure data, so all of one is worth looking at. Backticks
# are included for Go's raw strings, where a path is most likely to sit
# verbatim; the cost is that a `code span` in a comment is read as a literal
# too, which only matters if it looks like content and is undeclared.
STRING_LITERAL = re.compile(
    r"(?P<rawq>r?)'(?P<sq>[^'\n\\]*(?:\\.[^'\n\\]*)*)'"
    r"|(?P<rawqq>r?)\"(?P<dq>[^\"\n\\]*(?:\\.[^\"\n\\]*)*)\""
    r"|`(?P<bt>[^`]*)`")

# Markdown is mostly prose, so whole lines say nothing. Only tokens shaped
# like a path or a file name are data: a backslash-separated path, or anything
# ending in a media extension. Both forms of the leak this exists to stop
# (`<share>\<work>.pdf`) are caught by either half.
MD_BREAK = r'\s`\'"()<>|,、。（）「」'
MD_TOKEN = re.compile(
    r'[^%s]*(?:\\[^%s\\]+)+'
    r'|[^%s]+\.(?:pdf|zip|cbz|rar|jpe?g|png|gif|webp|mp4|mkv|avi|webm|mov'
    r'|wmv|m4v)\b' % (MD_BREAK, MD_BREAK, MD_BREAK),
    re.I,
)


class Policy:
    """What counts as private here: the vocabulary, the denylist, the scopes.

    Carried as one object because every check needs all of it, and threading
    five parameters through each of them was worse.
    """

    def __init__(self, root, args):
        self.root = root
        self.scanned = 0  # files and messages actually read this run
        vocab = abspath(root, args.vocabulary)
        self.vocabulary_known = os.path.exists(vocab)
        self.tokens, self.patterns = load_vocabulary(vocab)
        self.denylist = load_denylist(abspath(root, args.denylist))
        self.allow_current, self.allow_historical, self.keyed = \
            load_allow(abspath(root, args.allow))
        # The allow file is the ONLY file exempt from scanning. A historical:
        # entry is, by definition, a token new content must not contain, so
        # scanning the file would block the very act of declaring. The other
        # two declaration files stay scanned on purpose: a real name pasted
        # into the vocabulary should trip the denylist, and a denylist
        # committed into the repository is itself the worst possible leak --
        # scanning it makes it scream. Templates are also scanned: they get
        # copied anywhere, so they must be safe by content, not by path rule.
        self.allow_file = os.path.normpath(abspath(root, args.allow))
        self.data_scope = compile_all(args.data_scope or DEFAULT_DATA_SCOPE)
        scan = args.scan_scope or (
            tuple(args.data_scope or ()) + DEFAULT_SCAN_SCOPE)
        self.scan_scope = compile_all(scan)

    def in_scan_scope(self, path):
        if os.path.normpath(abspath(self.root, path)) == self.allow_file:
            return False
        return any(p.search(path) for p in self.scan_scope)

    def in_data_scope(self, path):
        return self.vocabulary_known and \
            any(p.search(path) for p in self.data_scope)

    def known(self, text):
        """Whether every segment of [text] is declared in the vocabulary."""
        if any(p.search(text) for p in self.patterns):
            return True
        segments = [s for s in re.split(r'[\\/]+', text) if s]
        if not segments:
            return True
        return all(s in self.tokens
                   or any(p.fullmatch(s) for p in self.patterns)
                   for s in segments)

    def allowed(self, hit, historical):
        """Whether this token was declared acceptable -- everywhere, or in
        already-existing revisions when [historical]."""
        return hit in self.allow_current or \
            (historical and hit in self.allow_historical)


def abspath(root, path):
    return path if os.path.isabs(path) else os.path.join(root, path)


def compile_all(patterns):
    return tuple(re.compile(p) for p in patterns)


def repo_root():
    """The repository being checked, or the directory holding this script."""
    done = subprocess.run(['git', 'rev-parse', '--show-toplevel'],
                          capture_output=True, text=True)
    if done.returncode == 0 and done.stdout.strip():
        return done.stdout.strip()
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def strip_comment(line):
    """'#' is a comment only at the start or after a space: it is also a legal
    character in a path segment, and `b#c` is a test case."""
    return re.sub(r'(?:^|\s)#.*$', '', line).strip()


def load_vocabulary(path):
    """Allowed path segments and file names, plus regexes for generated ones."""
    tokens, patterns = set(), []
    if not os.path.exists(path):
        return tokens, patterns
    with open(path, encoding='utf-8') as f:
        for line in f:
            line = strip_comment(line)
            if not line:
                continue
            if line.startswith('~'):
                patterns.append(re.compile(line[1:]))
            else:
                tokens.add(line)
    return tokens, patterns


def denylist_matcher(term):
    """How a denylist term may match, by character class.

    A bare substring fails in both directions. An alphanumeric id inside a
    longer token is a different value, so an ASCII term must not touch
    neighbouring alphanumerics. CJK prose has no word breaks, so a
    two-character name would stop every sentence containing it -- which kept
    such names off the list entirely, unprotected; a short CJK term instead
    matches only next to a delimiter (anything that is not a CJK letter),
    and a longer CJK title is distinctive enough to match anywhere.
    """
    esc = re.escape(term)
    if term.isascii():
        left = r'(?<![0-9A-Za-z])' if term[:1].isalnum() else ''
        right = r'(?![0-9A-Za-z])' if term[-1:].isalnum() else ''
        return re.compile(left + esc + right, re.I)
    if len(term) > 2:
        return re.compile(esc, re.I)
    return re.compile('(?<![%s])%s|%s(?![%s])'
                      % (CJK_RANGE, esc, esc, CJK_RANGE), re.I)


def load_denylist(path):
    """Denylist terms as (term, matcher) pairs."""
    if not os.path.exists(path):
        return []
    with open(path, encoding='utf-8') as f:
        return [(t, denylist_matcher(t))
                for t in (strip_comment(l) for l in f) if t]


def load_allow(path):
    """Declared exceptions. Three line forms (reasons live in comments above
    each entry, like cq-baseline.txt):

      TOKEN                  accepted everywhere
      historical: TOKEN      accepted only when scanning existing revisions
      key: NAME = V1 V2 ...  values that assignments to NAME may use
    """
    current, historical, keyed = set(), set(), {}
    if not os.path.exists(path):
        return current, historical, keyed
    with open(path, encoding='utf-8') as f:
        for line in f:
            line = strip_comment(line)
            if not line:
                continue
            if line.startswith('historical:'):
                historical.add(line[len('historical:'):].strip())
            elif line.startswith('key:'):
                name, _, values = line[len('key:'):].partition('=')
                keyed[name.strip()] = set(values.split())
            else:
                current.add(line)
    return current, historical, keyed


def looks_like_content(text, cjk_counts=True):
    """Whether this span is the kind of thing real data hides in.

    [cjk_counts] is false for Markdown, which may be written in a CJK
    language: there, only a path-shaped or media-named token can be data.
    """
    if cjk_counts and CJK.search(text):
        return True
    if MEDIA.search(text):
        return True
    if ESCAPE_NOT_PATH.match(text):
        return False
    return bool(re.search(r'[^\s\\/]\\[^\s\\/]', text))


def literals_of(path, content):
    """Every span in this file that is data rather than prose."""
    if path.endswith('.md'):
        for lineno, line in enumerate(content.split('\n'), 1):
            for m in MD_TOKEN.finditer(line):
                if m.group(0).strip():
                    yield lineno, m.group(0).strip()
        return
    for m in STRING_LITERAL.finditer(content):
        text = next((m.group(g) for g in ('sq', 'dq', 'bt')
                     if m.group(g) is not None), None)
        if not text:
            continue
        if not (m.group('rawq') or m.group('rawqq') or m.group('bt')):
            # Escapes are not path separators: `$e\n$st` is one line of log,
            # not a two-segment path.
            text = re.sub(r'\\(.)', r'\1', text)
        yield content[:m.start()].count('\n') + 1, text


def check_line(where, lineno, line, policy, historical):
    """The checks every scanned line gets: structural patterns, keyed example
    values, denylist. The denylist ignores the allow file on purpose: a known
    private name is never acceptable, only tolerated in history by removal."""
    problems = []
    for rx, why in STRUCTURAL:
        # Every match on the line, not just the first: a minified JSON line
        # carries many values, and stopping at one declared dummy id used to
        # hide every undeclared id behind it. Identical values are reported
        # once per line -- six copies of one leaked id are one problem.
        seen = set()
        for m in rx.finditer(line):
            hit = m.group(0)
            if hit in seen or policy.known(hit) \
                    or policy.allowed(hit, historical):
                continue
            seen.add(hit)
            problems.append((where, lineno, why, hit))
    for key, value in KEY_ASSIGN.findall(line):
        expected = policy.keyed.get(key)
        if expected is not None and value not in expected \
                and not policy.allowed(value, historical):
            problems.append((where, lineno,
                             '%s is not one of the example values' % key,
                             value))
    for term, rx in policy.denylist:
        if rx.search(line):
            problems.append((where, lineno, 'known private name', term))
    return problems


def check_content(path, content, policy, historical=False):
    policy.scanned += 1
    problems = []
    for lineno, line in enumerate(content.split('\n'), 1):
        problems += check_line(path, lineno, line, policy, historical)

    if policy.in_data_scope(path):
        cjk_counts = not path.endswith('.md')
        for lineno, text in literals_of(path, content):
            if looks_like_content(text, cjk_counts) and not policy.known(text) \
                    and not policy.allowed(text, historical):
                problems.append((path, lineno,
                                 'not in the test vocabulary', text))
    return problems


def git(root, *args):
    return subprocess.run(['git'] + list(args), cwd=root, capture_output=True,
                          text=True, errors='replace').stdout


def check_staged(policy):
    names = git(policy.root, 'diff', '--cached', '--name-only',
                '--diff-filter=ACMR').split('\n')
    problems = []
    for path in filter(None, names):
        if policy.in_scan_scope(path):
            problems += check_content(
                path, git(policy.root, 'show', ':' + path), policy)
    return problems


def check_worktree(policy):
    problems = []
    for path in filter(None, git(policy.root, 'ls-files').split('\n')):
        full = os.path.join(policy.root, path)
        if not policy.in_scan_scope(path) or not os.path.exists(full):
            continue
        with open(full, encoding='utf-8', errors='replace') as f:
            problems += check_content(path, f.read(), policy)
    return problems


def check_message(rev, policy):
    """A commit message carries data too, and is not caught by any file scan.
    Messages only exist in revisions, so the historical allowances apply."""
    policy.scanned += 1
    problems = []
    message = git(policy.root, 'log', '-1', '--format=%B', rev)
    for lineno, line in enumerate(message.split('\n'), 1):
        where = rev[:9] + ' (message)'
        problems += check_line(where, lineno, line, policy, historical=True)
        if not policy.vocabulary_known:
            continue
        for m in MD_TOKEN.finditer(line):
            token = m.group(0).strip()
            if looks_like_content(token, False) and not policy.known(token) \
                    and not policy.allowed(token, True):
                problems.append((where, lineno,
                                 'not in the test vocabulary', token))
    return problems


def check_revisions(revs, policy):
    """Every blob that ever existed shows up as changed in some revision, so
    scanning each revision's own changes covers the whole history once."""
    problems = []
    for rev in revs:
        problems += check_message(rev, policy)
        # --root: without it a parentless commit diffs as empty, and the
        # repository's first commit -- the largest data dump of all -- would
        # never be scanned by --range or --all-history.
        changed = git(policy.root, 'diff-tree', '--root', '-r', '--no-commit-id',
                      '--name-only', '--diff-filter=ACMR', rev).split('\n')
        for path in filter(None, changed):
            if not policy.in_scan_scope(path):
                continue
            content = git(policy.root, 'show', '%s:%s' % (rev, path))
            for p, lineno, why, hit in check_content(path, content, policy,
                                                     historical=True):
                problems.append(('%s %s' % (rev[:9], p), lineno, why, hit))
    return problems


def parse_args():
    ap = argparse.ArgumentParser(
        description='Fail on private data reaching this repository.')
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument('--staged', action='store_true')
    g.add_argument('--worktree', action='store_true')
    g.add_argument('--range')
    g.add_argument('--all-history', action='store_true')
    ap.add_argument('--vocabulary', metavar='PATH',
                    help='default: %s' % DEFAULT_VOCAB)
    ap.add_argument('--denylist', metavar='PATH',
                    help='default: %s' % DEFAULT_DENYLIST)
    ap.add_argument('--allow', metavar='PATH',
                    help='default: %s' % DEFAULT_ALLOW)
    ap.add_argument('--data-scope', action='append', metavar='RE')
    ap.add_argument('--scan-scope', action='append', metavar='RE')
    return ap.parse_args()


def report(problems, policy, args):
    print('Private data check failed:\n', file=sys.stderr)
    for path, lineno, why, hit in problems:
        print('  %s:%s: %s: %s' % (path, lineno, why, hit), file=sys.stderr)
    print('\n%d problem(s).\n' % len(problems), file=sys.stderr)
    print('A deliberate exception (an example value, a protocol constant) is',
          file=sys.stderr)
    print('declared in %s with its reason.' % args.allow, file=sys.stderr)
    if not policy.vocabulary_known:
        print('Only the structural checks ran: %s does not exist.'
              % args.vocabulary, file=sys.stderr)
        return
    print('If this is real data, replace it with names from %s.'
          % args.vocabulary, file=sys.stderr)
    print('If it is invented and the check is simply unaware of it, add it to '
          'that file', file=sys.stderr)
    print('-- that is the point: new test data is declared, not assumed.',
          file=sys.stderr)


def declared_path(given, default, root, option):
    """Resolve a declaration-file option.

    A path the user named must exist: these files decide what the scan can
    see, so a run that silently checks nothing is worse than one that fails.
    Measured: a trial clone without the private notes repository fed
    --all-history a nonexistent denylist, got 0 findings, and the
    verification passed on nothing (reported from na, 2026-08-16). An
    absent default stays fine -- not asking for a check is not an error.
    An empty file that exists also stays fine: --denylist /dev/null is how
    a run declares "no denylist", and readable emptiness is a statement.
    """
    if given is None:
        return default
    if not os.path.exists(abspath(root, given)):
        sys.stderr.write('error: the declaration file named by %s does not '
                         'exist: %s\n' % (option, given))
        sys.exit(2)
    return given


def main():
    args = parse_args()
    root = repo_root()
    args.vocabulary = declared_path(args.vocabulary, DEFAULT_VOCAB, root,
                                    '--vocabulary')
    args.denylist = declared_path(args.denylist, DEFAULT_DENYLIST, root,
                                  '--denylist')
    args.allow = declared_path(args.allow, DEFAULT_ALLOW, root, '--allow')
    policy = Policy(root, args)

    if args.staged:
        problems = check_staged(policy)
    elif args.worktree:
        problems = check_worktree(policy)
    else:
        spec = ['--all'] if args.all_history else [args.range]
        revs = [r for r in git(policy.root, 'rev-list', *spec).split('\n') if r]
        problems = check_revisions(revs, policy)

    # An absent DEFAULT denylist runs the scan without the known-names
    # check, and that green must not read like a checked green -- the same
    # contract check-text.py states for a missing textlint. Said once per
    # run, on stderr, only when something was actually scanned (a run that
    # read nothing has nothing to be quiet about), and without touching
    # the exit code: a checkout without the private notes repository still
    # has to be able to commit. Unlike vocabulary (deleting that file is
    # its documented off-switch) and allow (no declared exceptions is
    # normal), an absent denylist means nothing on purpose. Turning it off
    # deliberately is done by naming a readable empty file instead.
    if policy.scanned and not os.path.exists(abspath(root, args.denylist)):
        print('no denylist at %s; known names are not being checked.'
              % args.denylist, file=sys.stderr)

    if not problems:
        return 0
    report(problems, policy, args)
    return 1


if __name__ == '__main__':
    sys.exit(main())
