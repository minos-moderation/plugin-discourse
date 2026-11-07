"""The review trail of a pull request, checked in CI (`.github/workflows/review-trail.yml`).

A pull request that changes a path on the repository's risk list must carry, before it is
merged, a line

    Review: <agent> @ <head SHA> — AKCEPTACJA

for its CURRENT head: in its description, when its author may push to the repository, or
in a comment by someone who may (the repository permission `admin`, `maintain` or `write`).
The SHA is the full head or at least its first twelve characters; the verdict is
`AKCEPTACJA` or `POPRAWKI`, and the last line for the head decides. A path is on the risk
list unless the exempt list says otherwise (`exempt-paths.txt` beside this script, its own
header has the syntax). The line is a trace, not a proof, while sessions and the owner act
through one account.

    python3 check.py --event <event.json> --paths <changed paths> [-z] --exempt <exempt list>
                     [--pull <pull.json>] [--comments <comments.json>]
                     [--permissions <permissions.json>]

`--event` is the pull request's event (`$GITHUB_EVENT_PATH`; the workflow runs on
`pull_request_target`, so this script and the exempt list are the base branch's, and the
head's files are never checked out or run): it names the pull request and the head that was
diffed, nothing else of it is used. `--paths` holds one changed path per line
(`git diff --no-renames --name-only <base>...<head>`, so a moved file counts by both of its
paths), or with `-z` each path ended by a NUL, as `git diff -z` writes them: the workflow's
form, because only it gives every name as it is (without it git quotes a name with a byte
outside ASCII, a quote or a control character).

The description, the comments and the permissions are read live from GitHub's API with
`GITHUB_TOKEN` (`GITHUB_API_URL`, `GITHUB_REPOSITORY`), never from the event: the event's
`author_association` is computed for the app that receives it, which does not see a private
membership of the organisation, so the owner's own line could count as a stranger's; and a
re-run of the job sees what was written since. `--pull` (the pull request as
`GET /repos/{o}/{r}/pulls/{n}` returns it), `--comments` (its comments as
`GET /repos/{o}/{r}/issues/{n}/comments` lists them) and `--permissions` (an object, login →
the `permission` of `GET /repos/{o}/{r}/collaborators/{login}/permission`; a login missing
is `none`) stand in for the API. Exit 0: no path on the risk list, or the trail is there.
Exit 1: it is not. Exit 2: bad input, or the API cannot be read. Python 3.8+, stdlib only.

What the pull request or its event brings (a path, a login, a quoted review line) reaches
the job's log, where a line that starts with `::` (or holds `##[`) is a command to the
runner, so a file whose name holds a line break and `::notice::…` could forge an
annotation. Every such value is printed escaped (`shown`: `%25`, `%0A`, `%0D` as the
runner's own escaping, every other control character `%XX`, `##[` as `#%23[`) and never at
the start of a line; the workflow also stops the runner's commands around this script. The
description itself is never printed: only its length.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

#: The repository permissions whose holder's line counts: those who may push to it.
TRUSTED = {"admin", "maintain", "write"}

#: `Review: <agent> @ <sha> — <verdict>`; any dash between the SHA and the verdict.
REVIEW = re.compile(
    r"^[ \t>]*Review:[ \t]*(?P<agent>[\w.-]+)[ \t]*@[ \t]*(?P<sha>[0-9a-fA-F]{12,40})\b[ \t]*"
    r"[—–-]+[ \t]*(?P<verdict>\w+)",
    re.MULTILINE,
)

ACCEPTED = "AKCEPTACJA"

#: A character printed only escaped: the C0 and C1 controls (a line break among them), DEL,
#: the Unicode line and paragraph separators and a lone surrogate.
UNSAFE = re.compile(r"[\x00-\x1f\x7f-\x9f  \ud800-\udfff]")


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


class GitHub:
    """What the check reads of the pull request: live from GitHub's API, with
    `GITHUB_TOKEN`, unless a stand-in was given. A login's permission is read once."""

    def __init__(self, pull: dict | None = None, comments: list | None = None,
                 permissions: dict | None = None) -> None:
        self._pull = pull
        self._comments = comments
        self._permissions = permissions
        self._known: dict[str, str] = {}

    @staticmethod
    def _get(path: str, what: str, missing: object = ...) -> object:
        """One JSON document of the API.

        Args:
            path: The path below `/repos/{repository}/`.
            what: What it is, for the error.
            missing: What a 404 means, if it has a meaning; else a 404 is an error too.

        Raises:
            InputError: When it cannot be read.
        """
        api = os.environ.get("GITHUB_API_URL", "https://api.github.com").rstrip("/")
        repository = os.environ.get("GITHUB_REPOSITORY", "")
        token = os.environ.get("GITHUB_TOKEN", "")
        if not repository or not token:
            raise InputError(f"GITHUB_REPOSITORY and GITHUB_TOKEN are needed to read {what}")
        request = urllib.request.Request(
            f"{api}/repos/{repository}/{path}",
            headers={
                "Authorization": f"Bearer {token}",
                "Accept": "application/vnd.github+json",
                "X-GitHub-Api-Version": "2022-11-28",
            },
        )
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            if error.code == 404 and missing is not ...:
                return missing
            raise InputError(f"cannot read {what}: HTTP {error.code}") from None
        except (OSError, ValueError) as error:
            raise InputError(f"cannot read {what}: {error}") from None

    def pull(self, number: int) -> dict:
        """The pull request as it is now.

        Raises:
            InputError: When it cannot be read or is not an object.
        """
        if self._pull is None:
            self._pull = self._get(f"pulls/{number}", "the pull request")
        if not isinstance(self._pull, dict):
            raise InputError("the pull request is not an object")
        return self._pull

    def comments(self, number: int) -> list[dict]:
        """Every comment of the pull request, oldest first.

        Raises:
            InputError: When they cannot be read.
        """
        if self._comments is None:
            comments: list[dict] = []
            for page in range(1, 101):
                batch = self._get(f"issues/{number}/comments?per_page=100&page={page}", "the pull request's comments")
                if not isinstance(batch, list):
                    raise InputError("the comments are not a list")
                comments.extend(batch)
                if len(batch) < 100:
                    break
            else:
                raise InputError("more than 10,000 comments")
            self._comments = comments
        return [comment for comment in self._comments if isinstance(comment, dict)]

    def permission(self, login: str) -> str:
        """A login's permission in the repository: `admin`, `write`, `read` or `none` (the
        API's `permission`, where `maintain` reads as `write`); `none` for no login and for
        one the API does not know.

        Raises:
            InputError: When the API cannot be read.
        """
        if not login:
            return "none"
        if login not in self._known:
            if self._permissions is not None:
                found = self._permissions.get(login, "none")
            else:
                answer = self._get(f"collaborators/{urllib.parse.quote(login, safe='')}/permission",
                                   "a permission", missing={})
                found = answer.get("permission", "none") if isinstance(answer, dict) else "none"
            self._known[login] = str(found or "none")
        return self._known[login]


def reviews(text: str) -> list[tuple[str, str, str]]:
    """The review lines of a text, in order: (agent, SHA in lower case, verdict in upper case)."""
    return [
        (m.group("agent"), m.group("sha").lower(), m.group("verdict").upper())
        for m in REVIEW.finditer(text or "")
    ]


def login_of(item: dict) -> str:
    """The login of who wrote a pull request or a comment, or an empty string."""
    user = item.get("user")
    login = user.get("login") if isinstance(user, dict) else None
    return login if isinstance(login, str) else ""


def decide(event: dict, paths: list[str], exempt: list[str], risk: list[str],
           github: GitHub) -> tuple[bool, list[str]]:
    """Whether the pull request passes, and the lines that say why.

    Args:
        event: The `pull_request` event.
        paths: The changed paths.
        exempt: The exempt patterns.
        risk: The risk patterns that win over them.
        github: What the pull request is now (read only when a path needs a review).

    Returns:
        The decision and its explanation.

    Raises:
        InputError: When the event is not a pull request's, or the API cannot be read.
    """
    pull = event.get("pull_request")
    if not isinstance(pull, dict):
        raise InputError("the event is not a pull_request event")
    head = str((pull.get("head") or {}).get("sha", "")).lower()
    if not re.fullmatch(r"[0-9a-f]{40}", head):
        raise InputError("the event names no head SHA")
    number = pull.get("number")
    if not isinstance(number, int) or isinstance(number, bool) or number < 1:
        raise InputError("the event names no pull request number")
    risky = [path for path in paths if needs_review(path, exempt, risk)]
    if not risky:
        return True, [f"No changed path is on the risk list ({len(paths)} changed): no review line is required."]
    lines = [f"{len(risky)} changed path(s) on the risk list, for example:"]
    # A fixed mark before each path: no line starts with what the pull request named.
    lines += [f"  - {shown(path)}" for path in risky[:10]]

    now = github.pull(number)
    now_head = str((now.get("head") or {}).get("sha", "")).lower()
    if now_head != head:
        lines.append(f"The pull request's head is now {shown(now_head)}, not this run's {head}: the run for it decides.")
        return False, lines
    body = now.get("body")
    body = body if isinstance(body, str) else ""
    author = login_of(now)
    permission = github.permission(author)
    # The one diagnostic line: who wrote the description, what they may do, how long it is.
    lines.append(f"The description: {len(body)} character(s), by {shown(author or '?')}, permission "
                 f"{shown(permission)} (the event's author_association: {shown(pull.get('author_association'))}).")
    found = []
    if permission in TRUSTED:
        found += [("the description", review) for review in reviews(body)]
    ignored = set()
    for comment in github.comments(number):
        lines_of = reviews(comment.get("body") if isinstance(comment.get("body"), str) else "")
        if not lines_of:
            continue
        login = login_of(comment)
        if github.permission(login) in TRUSTED:
            found += [(f"a comment by {shown(login)}", review) for review in lines_of]
        else:
            ignored.add(f"{shown(login or '?')} ({shown(github.permission(login))})")
    if ignored:
        lines.append(f"Not counted, by someone who may not push: the review line(s) of {', '.join(sorted(ignored))}.")
    current = [(where, review) for where, review in found if head.startswith(review[1])]
    if not current:
        lines.append(f"No line `Review: <agent> @ {head} — {ACCEPTED}` for the head (the full SHA or its first "
                     f"12 characters or more), in the description or a comment by someone who may push "
                     f"({len(found)} review line(s) for other commits).")
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
    parser.add_argument("--pull")
    parser.add_argument("--comments")
    parser.add_argument("--permissions")
    try:
        args = parser.parse_args(argv)
    except SystemExit:
        return 2
    try:
        exempt, risk = read_exempt(args.exempt)
        given = {}
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
            for name in ("pull", "comments", "permissions"):
                if getattr(args, name) is not None:
                    with open(getattr(args, name), encoding="utf-8") as handle:
                        given[name] = json.load(handle)
        except (OSError, ValueError) as error:
            raise InputError(f"cannot read the input: {error}") from None
        kinds = {"pull": dict, "comments": list, "permissions": dict}
        if not isinstance(event, dict) or any(not isinstance(given[name], kinds[name]) for name in given):
            raise InputError("the event, the pull request and the permissions must be objects and the comments a list")
        passed, lines = decide(event, paths, exempt, risk, GitHub(**given))
    except InputError as error:
        print(f"review trail: {shown(error)}", file=sys.stderr)
        return 2
    print("\n".join(lines))
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
