"""The review trail of a pull request, checked in CI (`.github/workflows/review-trail.yml`).

A pull request that changes a path on the repository's risk list must carry, before it is
merged, a line

    Review: <agent> @ <head SHA> — AKCEPTACJA

for its CURRENT head: in its description, or in a comment by a member of the repository
(`OWNER`, `MEMBER` or `COLLABORATOR`). The SHA is the full head or at least its first twelve
characters; the verdict is `AKCEPTACJA` or `POPRAWKI`, and the last line for the head
decides. A path is on the risk list unless the exempt list says otherwise
(`exempt-paths.txt` beside this script, its own header has the syntax). The line is a
trace, not a proof, while sessions and the owner act through one account.

    python3 check.py --event <event.json> --paths <changed paths> [-z] --exempt <exempt list>
                     [--comments <comments.json>]

`--event` is the pull request's event (`$GITHUB_EVENT_PATH`; the workflow runs on
`pull_request_target`, so this script and the exempt list are the base branch's, and the
head's files are never checked out or run); `--paths` holds one changed
path per line (`git diff --no-renames --name-only <base>...<head>`, so a moved file counts by
both of its paths), or with `-z` each path ended by a NUL, as `git diff -z` writes them: the
workflow's form, because only it gives every name as it is (without it git quotes a name
with a byte outside ASCII, a quote or a control character); `--comments` is the pull request's
comments as GitHub's API lists them, which are otherwise read from the API with
`GITHUB_TOKEN` (`GITHUB_API_URL`, `GITHUB_REPOSITORY`). Exit 0: no path on the risk list,
or the trail is there. Exit 1: it is not. Exit 2: bad input. Python 3.8+, stdlib only.

What the pull request or its event brings (a path, a login, a quoted review line) reaches
the job's log, where a line that starts with `::` (or holds `##[`) is a command to the
runner, so a file whose name holds a line break and `::notice::…` could forge an
annotation. Every such value is printed escaped (`shown`: `%25`, `%0A`, `%0D` as the
runner's own escaping, every other control character `%XX`, `##[` as `#%23[`) and never at
the start of a line; the workflow also stops the runner's commands around this script.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.request

#: The authors whose comments count: people with a role in the repository.
TRUSTED = {"OWNER", "MEMBER", "COLLABORATOR"}

#: `Review: <agent> @ <sha> — <verdict>`; any dash between the SHA and the verdict.
REVIEW = re.compile(
    r"^[ \t>]*Review:[ \t]*(?P<agent>[\w.-]+)[ \t]*@[ \t]*(?P<sha>[0-9a-fA-F]{12,40})\b[ \t]*"
    r"[\u2014\u2013-]+[ \t]*(?P<verdict>\w+)",
    re.MULTILINE,
)

ACCEPTED = "AKCEPTACJA"

#: A character printed only escaped: the C0 and C1 controls (a line break among them), DEL,
#: the Unicode line and paragraph separators and a lone surrogate.
UNSAFE = re.compile(r"[\x00-\x1f\x7f-\x9f\u2028\u2029\ud800-\udfff]")


class InputError(Exception):
    """The input cannot be read as what it should be."""


def shown(value: object) -> str:
    """A value from the pull request or its event as the log may show it: on one line, with
    no `%` that a reader could take for an escape of ours and no legacy `##[` command.

    Args:
        value: The value (a path, a login, a part of a review line).

    Returns:
        The value with `%` as `%25`, every character of `UNSAFE` as `%XX` (`%uXXXX` above
        U+00FF; a line break is `%0A` or `%0D`, as the runner escapes them) and `##[` as
        `#%23[`.
    """
    text = str(value).replace("%", "%25")
    text = UNSAFE.sub(lambda m: f"%{ord(m.group()):02X}" if ord(m.group()) < 0x100 else f"%u{ord(m.group()):04X}", text)
    return text.replace("##[", "#%23[")


def read_exempt(path: str) -> tuple[list[str], list[str]]:
    """Reads the exempt list: its patterns, and the `!` patterns that win over them.

    Args:
        path: The list's file.

    Returns:
        The exempt patterns and the risk patterns.

    Raises:
        InputError: When the file cannot be read or holds no pattern.
    """
    try:
        with open(path, encoding="utf-8") as handle:
            lines = handle.read().splitlines()
    except OSError as error:
        raise InputError(f"cannot read the exempt list {path}: {error.strerror}") from None
    exempt, risk = [], []
    for line in lines:
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        (risk if line.startswith("!") else exempt).append(line.lstrip("!"))
    if not exempt:
        raise InputError(f"the exempt list {path} has no pattern")
    return exempt, risk


def matches(path: str, pattern: str) -> bool:
    """Whether a path matches a pattern: `dir/` everything below it, `**/name` a file of
    that name anywhere, anything else the exact path."""
    if pattern.endswith("/"):
        return path.startswith(pattern)
    if pattern.startswith("**/"):
        return path == pattern[3:] or path.endswith("/" + pattern[3:])
    return path == pattern


def needs_review(path: str, exempt: list[str], risk: list[str]) -> bool:
    """Whether a changed path is on the risk list: it is unless an exempt pattern matches it
    and no risk pattern does."""
    if any(matches(path, pattern) for pattern in risk):
        return True
    return not any(matches(path, pattern) for pattern in exempt)


def fetch_comments(number: int) -> list[dict]:
    """Every comment of the pull request, from GitHub's API, oldest first.

    Raises:
        InputError: When the API cannot be read.
    """
    api = os.environ.get("GITHUB_API_URL", "https://api.github.com").rstrip("/")
    repository = os.environ.get("GITHUB_REPOSITORY", "")
    token = os.environ.get("GITHUB_TOKEN", "")
    if not repository or not token:
        raise InputError("GITHUB_REPOSITORY and GITHUB_TOKEN are needed to read the comments")
    comments: list[dict] = []
    for page in range(1, 101):
        request = urllib.request.Request(
            f"{api}/repos/{repository}/issues/{number}/comments?per_page=100&page={page}",
            headers={
                "Authorization": f"Bearer {token}",
                "Accept": "application/vnd.github+json",
                "X-GitHub-Api-Version": "2022-11-28",
            },
        )
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                batch = json.load(response)
        except (OSError, ValueError) as error:
            raise InputError(f"cannot read the pull request's comments: {error}") from None
        if not isinstance(batch, list):
            raise InputError("the comments are not a list")
        comments.extend(batch)
        if len(batch) < 100:
            return comments
    raise InputError("more than 10,000 comments")


def reviews(text: str) -> list[tuple[str, str, str]]:
    """The review lines of a text, in order: (agent, SHA in lower case, verdict in upper case)."""
    return [
        (m.group("agent"), m.group("sha").lower(), m.group("verdict").upper())
        for m in REVIEW.finditer(text or "")
    ]


def decide(event: dict, paths: list[str], exempt: list[str], risk: list[str],
           comments: list[dict] | None) -> tuple[bool, list[str]]:
    """Whether the pull request passes, and the lines that say why.

    Args:
        event: The `pull_request` event.
        paths: The changed paths.
        exempt: The exempt patterns.
        risk: The risk patterns that win over them.
        comments: The comments, or None to read them from the API (only when needed).

    Returns:
        The decision and its explanation.

    Raises:
        InputError: When the event is not a pull request's, or the comments cannot be read.
    """
    pull = event.get("pull_request")
    if not isinstance(pull, dict):
        raise InputError("the event is not a pull_request event")
    head = str((pull.get("head") or {}).get("sha", "")).lower()
    if not re.fullmatch(r"[0-9a-f]{40}", head):
        raise InputError("the event names no head SHA")
    risky = [path for path in paths if needs_review(path, exempt, risk)]
    if not risky:
        return True, [f"No changed path is on the risk list ({len(paths)} changed): no review line is required."]
    lines = [f"{len(risky)} changed path(s) on the risk list, for example:"]
    # A fixed mark before each path: no line starts with what the pull request named.
    lines += [f"  - {shown(path)}" for path in risky[:10]]
    found = []
    if pull.get("author_association") in TRUSTED:
        found += [("the description", review) for review in reviews(pull.get("body") or "")]
    if comments is None:
        comments = fetch_comments(int(pull.get("number", 0)))
    for comment in comments:
        if comment.get("author_association") in TRUSTED:
            login = (comment.get("user") or {}).get("login", "?")
            found += [(f"a comment by {shown(login)}", review) for review in reviews(comment.get("body") or "")]
    current = [(where, review) for where, review in found if head.startswith(review[1])]
    if not current:
        lines.append(f"No line `Review: <agent> @ {head} — {ACCEPTED}` for the head (the full SHA or its first "
                     f"12 characters or more), in the description or a member's comment ({len(found)} review "
                     f"line(s) for other commits).")
        return False, lines
    where, (agent, sha, verdict) = current[-1]
    if verdict != ACCEPTED:
        lines.append(f"The last review of the head ({shown(agent)} @ {sha}, in {where}) says {shown(verdict)}, "
                     f"not {ACCEPTED}.")
        return False, lines
    lines.append(f"Reviewed: {shown(agent)} @ {sha} — {shown(verdict)}, in {where}.")
    return True, lines


def main(argv: list[str]) -> int:
    """The command line: see the module's docstring."""
    parser = argparse.ArgumentParser(description="Checks a pull request's review trail.")
    parser.add_argument("--event", required=True)
    parser.add_argument("--paths", required=True)
    parser.add_argument("-z", dest="nul", action="store_true")
    parser.add_argument("--exempt", required=True)
    parser.add_argument("--comments")
    try:
        args = parser.parse_args(argv)
    except SystemExit:
        return 2
    try:
        exempt, risk = read_exempt(args.exempt)
        try:
            with open(args.event, encoding="utf-8") as handle:
                event = json.load(handle)
            if args.nul:
                # Verbatim: no newline translation, no stripping; a name may hold either.
                with open(args.paths, encoding="utf-8", newline="") as handle:
                    paths = [path for path in handle.read().split("\0") if path]
            else:
                with open(args.paths, encoding="utf-8") as handle:
                    paths = [line.strip() for line in handle if line.strip()]
            comments = None
            if args.comments is not None:
                with open(args.comments, encoding="utf-8") as handle:
                    comments = json.load(handle)
        except (OSError, ValueError) as error:
            raise InputError(f"cannot read the input: {error}") from None
        if not isinstance(event, dict) or (comments is not None and not isinstance(comments, list)):
            raise InputError("the event must be an object and the comments a list")
        passed, lines = decide(event, paths, exempt, risk, comments)
    except InputError as error:
        print(f"review trail: {shown(error)}", file=sys.stderr)
        return 2
    print("\n".join(lines))
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
