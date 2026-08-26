#!/usr/bin/env python3
"""Triage which OPEN issues a recently merged pull request might close.

This tool produces a SHORTLIST FOR HUMAN REVIEW only. It never closes issues.

It gathers the changeset of one merged pull request (the most recently merged PR
by default, e.g. a sync) together with the target repository's open issues, asks
a GitHub Models chat model which issues the change plausibly resolves, and writes
a Markdown shortlist to ``GITHUB_STEP_SUMMARY`` plus artifact files.

Because GitHub Models caps "high" models (such as ``openai/gpt-4o``) at 8000
input tokens per request on the Free/Pro/Business tiers, the open issues are
split into character-budgeted batches and analyzed one batch per request; the
candidates are then merged.

Only the Python standard library is used. The ``gh`` CLI must be installed and
authenticated (the workflow provides ``GH_TOKEN``). Inference uses the GitHub
Models REST API with a token that has the ``models: read`` permission.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import textwrap
import time
import urllib.error
import urllib.request
from typing import Any, Iterable

MODELS_API_URL = "https://models.github.ai/inference/chat/completions"
MODELS_API_VERSION = "2026-03-10"


# --------------------------------------------------------------------------- #
# Small helpers
# --------------------------------------------------------------------------- #
def _log(message: str) -> None:
    print(message, file=sys.stderr, flush=True)


def _gh(args: list[str]) -> str:
    """Run a ``gh`` command and return stdout, raising on failure."""
    result = subprocess.run(["gh", *args], capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(
            f"`gh {' '.join(args)}` failed ({result.returncode}):\n{result.stderr.strip()}"
        )
    return result.stdout


def _gh_json(args: list[str]) -> Any:
    return json.loads(_gh(args))


def _truncate(text: str, limit: int, marker: str = "\n... [truncated] ...") -> str:
    text = text or ""
    if limit <= 0 or len(text) <= limit:
        return text
    return text[:limit].rstrip() + marker


def _emit_outputs(pairs: dict[str, str]) -> None:
    """Write key=value pairs to GITHUB_OUTPUT (multi-line safe)."""
    path = os.environ.get("GITHUB_OUTPUT")
    if not path:
        return
    with open(path, "a", encoding="utf-8") as handle:
        for key, value in pairs.items():
            if "\n" in value:
                delim = f"__EOF_{key}__"
                handle.write(f"{key}<<{delim}\n{value}\n{delim}\n")
            else:
                handle.write(f"{key}={value}\n")


def _resolve_token() -> str:
    for name in ("MODELS_TOKEN", "GITHUB_TOKEN", "GH_TOKEN"):
        value = os.environ.get(name)
        if value:
            return value
    # Last resort for local runs: ask the gh CLI for its token.
    try:
        return _gh(["auth", "token"]).strip()
    except Exception:  # noqa: BLE001
        return ""


# --------------------------------------------------------------------------- #
# Gather: pull request changeset + open issues
# --------------------------------------------------------------------------- #
def resolve_default_branch(repo: str) -> str:
    try:
        data = _gh_json(["repo", "view", repo, "--json", "defaultBranchRef"])
        name = (data.get("defaultBranchRef") or {}).get("name")
        if name:
            return name
    except Exception as exc:  # noqa: BLE001 - best effort
        _log(f"Could not resolve default branch for {repo}: {exc}")
    return "main"


def resolve_pr_number(repo: str, pr_number: str, base_branch: str) -> int:
    if pr_number and pr_number.strip():
        return int(pr_number.strip())

    # `gh pr list` orders by creation (PR number), not merge time, so the most
    # recently MERGED PR can fall outside a small creation-ordered window. Sort by
    # most-recently-updated (a merge updates the PR) over a generous window, then
    # select the maximum mergedAt explicitly.
    def _merged_rows(extra: list[str]) -> list[dict[str, Any]]:
        rows = _gh_json(
            [
                "pr", "list", "--repo", repo,
                "--state", "merged", "--base", base_branch,
                *extra, "--json", "number,mergedAt",
            ]
        )
        return [row for row in rows if row.get("mergedAt")]

    try:
        rows = _merged_rows(["--search", "sort:updated-desc", "--limit", "100"])
    except Exception as exc:  # noqa: BLE001 - fall back to default ordering
        _log(f"updated-desc PR search failed ({exc}); falling back to default ordering.")
        rows = _merged_rows(["--limit", "100"])
    if not rows:
        raise RuntimeError(
            f"No merged pull requests found on {repo}:{base_branch} to analyze."
        )
    latest = max(rows, key=lambda row: row["mergedAt"])
    return int(latest["number"])


def fetch_pr(repo: str, pr_number: int) -> dict[str, Any]:
    return _gh_json(
        [
            "pr", "view", str(pr_number), "--repo", repo,
            "--json", "number,title,body,url,mergedAt,author,commits,files",
        ]
    )


def fetch_diff(repo: str, pr_number: int) -> str:
    try:
        return _gh(["pr", "diff", str(pr_number), "--repo", repo])
    except Exception as exc:  # noqa: BLE001 - diff is best effort
        _log(f"Could not fetch diff for PR #{pr_number}: {exc}")
        return ""


def fetch_open_issues(repo: str, max_issues: int) -> list[dict[str, Any]]:
    return _gh_json(
        [
            "issue", "list", "--repo", repo,
            "--state", "open", "--limit", str(max_issues),
            "--json", "number,title,body,labels,url",
        ]
    )


# --------------------------------------------------------------------------- #
# Build prompt pieces
# --------------------------------------------------------------------------- #
def build_changeset_md(pr: dict[str, Any], limits: dict[str, int]) -> str:
    """Compact changeset summary for the prompt (no raw diff, to fit the cap)."""
    lines: list[str] = []
    lines.append(f"Merged pull request #{pr['number']}: {pr.get('title', '').strip()}")
    author = (pr.get("author") or {}).get("login") or "unknown"
    lines.append(f"Author: @{author} | Merged at: {pr.get('mergedAt', '')}")

    body = _truncate((pr.get("body") or "").strip(), limits["pr_body"])
    if body:
        lines.append("")
        lines.append("Description:")
        lines.append(body)

    commits = pr.get("commits") or []
    lines.append("")
    lines.append(f"Commits ({len(commits)}):")
    for commit in commits:
        oid = (commit.get("oid") or "")[:10]
        headline = (commit.get("messageHeadline") or "").strip()
        lines.append(f"- {oid} {headline}")

    files = pr.get("files") or []
    shown = files[: limits["files_in_prompt"]]
    lines.append("")
    lines.append(f"Changed files ({len(files)}):")
    for entry in shown:
        lines.append(f"- {entry.get('path', '')}")
    if len(files) > len(shown):
        lines.append(f"- ... and {len(files) - len(shown)} more file(s)")

    changeset = "\n".join(lines)
    return _truncate(changeset, limits["changeset"], "\n... [changeset truncated] ...")


def issue_block(issue: dict[str, Any], body_limit: int) -> str:
    labels = ", ".join(lbl.get("name", "") for lbl in (issue.get("labels") or []))
    parts = [f"### Issue #{issue['number']}: {issue.get('title', '').strip()}"]
    if labels:
        parts.append(f"Labels: {labels}")
    body = _truncate((issue.get("body") or "").strip(), body_limit, " ...")
    parts.append(body if body else "(no description)")
    return "\n".join(parts) + "\n"


SYSTEM_PROMPT = textwrap.dedent(
    """\
    You are a meticulous software maintainer triaging a bug tracker. You are given
    the changeset of ONE merged pull request and a batch of OPEN issues from the
    same repository. Identify which of those open issues the merged change plausibly
    FIXES, RESOLVES, or fully IMPLEMENTS.

    This is a triage shortlist that a human reviews before any issue is closed, so
    favour precision over recall and justify every candidate with concrete evidence
    from the changeset (commit subjects, file paths, or described behaviour).

    Rules:
    - Only reference issue numbers that appear in the provided batch. Never invent
      issue numbers.
    - Include an issue only if the merged change directly addresses it. Do not
      include issues that are merely "related" or "adjacent".
    - Confidence is an integer 0-100:
        80-100  strong, direct fix clearly present in this changeset
        50-79   likely fix, a reviewer should confirm
        30-49   possible match worth a human look
        below 30  omit entirely
    - Feature requests/discussions: include only if the change clearly implements them.
    - If nothing in this batch matches, return an empty candidate list.

    Respond with a SINGLE JSON object and nothing else, exactly in this shape:
    {"candidates": [{"issue_number": 123, "title": "short title", "confidence": 75,
    "rationale": "1-3 sentences citing the change", "supporting_evidence": "commit
    shas / file paths"}]}
    """
)


def build_user_prompt(changeset_md: str, issues_md: str, batch_count: int) -> str:
    return (
        "Analyze the merged pull request changeset and decide which of the "
        f"{batch_count} open issues in this batch it plausibly closes. Follow the "
        "system prompt's rules and JSON output contract exactly.\n\n"
        "===== MERGED PULL REQUEST CHANGESET =====\n"
        f"{changeset_md}\n\n"
        f"===== OPEN ISSUES (this batch: {batch_count}) =====\n"
        f"{issues_md}\n\n"
        'Return ONLY the JSON object {"candidates": [...]}. If no issue in this '
        'batch is closed by the change, return {"candidates": []}.'
    )


def iter_issue_batches(
    issues: list[dict[str, Any]], fixed_prefix_chars: int,
    max_request_chars: int, body_limit: int,
) -> Iterable[list[dict[str, Any]]]:
    """Group issues so each request stays under the character budget."""
    budget = max(max_request_chars - fixed_prefix_chars, 2000)
    batch: list[dict[str, Any]] = []
    used = 0
    for issue in issues:
        block_len = len(issue_block(issue, body_limit))
        if batch and used + block_len > budget:
            yield batch
            batch, used = [], 0
        batch.append(issue)
        used += block_len
    if batch:
        yield batch


# --------------------------------------------------------------------------- #
# Stage 1.5 — deterministic mechanism grounding
# --------------------------------------------------------------------------- #
# A frequent false-positive mode is matching an issue to a commit that touches the
# SAME file/subsystem but fixes a DIFFERENT bug (e.g. an issue about a download
# size-limit crash matched to an unrelated cursor-cleanup change). The model never
# sees the diff (only commit subjects + file paths), so it cannot tell them apart.
# These helpers extract the concrete identifiers/error-strings an issue names and
# check whether they actually appear in the PR diff, providing a cheap, deterministic
# grounding signal and a focused diff excerpt for the stage-2 verification.

# Generic words that are not distinctive enough to ground a match.
_GENERIC_TOKENS = {
    "documentdb", "document", "database", "collection", "collections", "server",
    "error", "errors", "issue", "result", "results", "expected", "actual", "value",
    "values", "field", "fields", "version", "versions", "command", "commands",
    "query", "queries", "support", "feature", "request", "behavior", "behaviour",
    "operator", "operators", "function", "functions", "postgres", "postgresql",
    "create", "insert", "update", "delete", "select", "return", "returns", "should",
    "running", "system", "client", "string", "number", "object", "array", "index",
    "files", "file", "using", "tests", "test", "github", "mongosh", "mongofiles",
}

_CAMEL_RE = re.compile(r"\b[A-Za-z][a-zA-Z0-9]*[a-z][A-Z][A-Za-z0-9]*\b")
_SNAKE_RE = re.compile(r"\b[a-zA-Z][a-zA-Z0-9]*(?:_[a-zA-Z0-9]+)+\b")
_DOLLAR_RE = re.compile(r"\$[A-Za-z][A-Za-z0-9]*")
_FILE_RE = re.compile(
    r"\b[\w./-]+\.(?:c|h|cpp|hpp|sql|sh|rs|js|ts|py|spec|toml|ya?ml|md|conf|service|control|out)\b"
)
_BACKTICK_RE = re.compile(r"`([^`\n]{2,80})`")
_QUOTED_RE = re.compile(r"[\"'\u201c\u2018]([^\"'\u201c\u201d\u2018\u2019\n]{12,120})[\"'\u201d\u2019]")


def extract_issue_signals(issue: dict[str, Any]) -> dict[str, list[str]]:
    """Pull distinctive identifiers and error-phrases an issue names.

    Returns {"tokens": [...distinctive identifiers...], "phrases": [...error strings...]}.
    Tokens/phrases are lowercased for case-insensitive substring matching against a diff.
    """
    text = f"{issue.get('title', '')}\n{issue.get('body', '')}"
    tokens: set[str] = set()

    for match in _CAMEL_RE.findall(text):
        tokens.add(match)
    for match in _SNAKE_RE.findall(text):
        tokens.add(match)
    for match in _DOLLAR_RE.findall(text):
        tokens.add(match)
    for match in _FILE_RE.findall(text):
        tokens.add(match)
    for span in _BACKTICK_RE.findall(text):
        span = span.strip()
        # A short backticked identifier is a strong signal; longer spans are commands.
        if span and " " not in span and len(span) >= 4:
            tokens.add(span)

    distinctive: list[str] = []
    for tok in tokens:
        low = tok.lower()
        base = low.lstrip("$")
        if base in _GENERIC_TOKENS:
            continue
        # Keep identifiers that look specific: camel/snake/$-op/filename, or long.
        if (
            "$" in tok or "_" in tok or "." in tok
            or any(c.isupper() for c in tok[1:])
            or len(base) >= 7
        ):
            distinctive.append(low)

    phrases = []
    for span in _QUOTED_RE.findall(text):
        span = " ".join(span.split()).lower()
        if span and not span.startswith(("http", "{", "[")):
            phrases.append(span)

    # De-duplicate, keep order stable, cap to keep prompts bounded.
    tokens_out = list(dict.fromkeys(distinctive))[:25]
    phrases_out = list(dict.fromkeys(phrases))[:8]
    return {"tokens": tokens_out, "phrases": phrases_out}


def grounding_for_issue(signals: dict[str, list[str]], diff_lower: str) -> dict[str, Any]:
    """Count how many of an issue's distinctive signals appear in the PR diff."""
    tokens = signals["tokens"]
    phrases = signals["phrases"]
    matched = [t for t in tokens if t in diff_lower]
    matched_phrases = [p for p in phrases if p in diff_lower]
    total_strong = len(tokens) + len(phrases)
    hits = len(matched) + len(matched_phrases)
    return {
        "strong_signal_count": total_strong,
        "hits": hits,
        "matched": (matched + matched_phrases)[:12],
    }


def extract_focused_diff(diff: str, signals: dict[str, list[str]], limit: int,
                         per_hunk_cap: int = 1400) -> str:
    """Return whole diff hunks that mention any of the issue's signals.

    Earlier this took only a few lines around each match, which often captured a
    nearby comment but not the actual fix line, leaving the verifier under-informed.
    Including the complete hunk (the full ``@@ ... @@`` block, with its file path)
    lets the verifier see the real added/removed code. Oversized hunks are windowed
    around the first match so one huge hunk cannot exhaust the budget.
    """
    needles = [s for s in (signals["tokens"] + signals["phrases"]) if s]
    if not needles or not diff:
        return ""

    # Split the diff into hunks, each tagged with the file it belongs to.
    hunks: list[dict[str, Any]] = []
    cur_file = ""
    cur: dict[str, Any] | None = None
    for line in diff.split("\n"):
        if line.startswith("diff --git"):
            cur = None
            cur_file = line
        elif line.startswith("+++ ") and not cur_file:
            cur_file = line
        elif line.startswith("@@"):
            cur = {"file": cur_file, "header": line, "body": []}
            hunks.append(cur)
        elif cur is not None and not line.startswith(("--- ", "+++ ", "index ")):
            cur["body"].append(line)

    parts: list[str] = []
    total = 0
    for hunk in hunks:
        body = hunk["body"]
        blob = "\n".join([hunk["file"], hunk["header"], *body]).lower()
        if not any(needle in blob for needle in needles):
            continue
        head = [hunk["file"]] if hunk["file"] else []
        head.append(hunk["header"])
        full = "\n".join([*head, *body])
        if len(full) <= per_hunk_cap:
            piece = full
        else:
            # Window around the first matching body line to keep the fix in view.
            match_idx = next(
                (k for k, ln in enumerate(body) if any(n in ln.lower() for n in needles)), 0
            )
            lo = max(0, match_idx - 12)
            hi = min(len(body), match_idx + 16)
            piece = _truncate("\n".join([*head, *body[lo:hi]]), per_hunk_cap)
        if parts and total + len(piece) > limit:
            break
        parts.append(piece)
        total += len(piece)
        if total >= limit:
            break
    return _truncate("\n".join(parts), limit, "\n... [excerpt truncated] ...")


# --------------------------------------------------------------------------- #
# Stage 2 — diff-aware verification
# --------------------------------------------------------------------------- #
STAGE2_SYSTEM_PROMPT = textwrap.dedent(
    """\
    You are verifying whether a merged pull request's code change ACTUALLY fixes
    specific issues. For each (issue, diff excerpt) pair, decide one verdict:
    - CONFIRMED: the diff implements a fix for the SPECIFIC symptom, trigger, or
      error the issue describes (for a feature request: the requested capability is
      implemented in the diff).
    - PARTIAL: genuinely related but incomplete — addresses part of the issue, is one
      step of a larger required change, or is gated/preconditioned.
    - FALSE_POSITIVE: touches the same file/subsystem/theme but does NOT fix the
      issue's specific problem.

    Critical rules:
    - Same file or subsystem is NOT proof. A different bug in the same area is a
      FALSE_POSITIVE.
    - Your "evidence" MUST quote an actual added/removed code line (starting with
      '+' or '-') from the diff excerpt that implements the fix. If you cannot quote
      such a line, the verdict cannot be CONFIRMED.
    - If the diff excerpt is empty or unrelated to the issue's described mechanism,
      return FALSE_POSITIVE.

    Respond with a SINGLE JSON object and nothing else, exactly:
    {"verifications": [{"issue_number": 123, "verdict": "CONFIRMED",
    "confidence": 90, "rationale": "1-3 sentences", "evidence": "quoted +/- diff line"}]}
    """
)


def build_stage2_prompt(items: list[dict[str, Any]]) -> str:
    parts = [
        "Verify each issue below against its diff excerpt from the merged pull request. "
        "Follow the system prompt's verdicts, rules, and JSON contract exactly.\n",
    ]
    for it in items:
        parts.append(f"===== ISSUE #{it['number']}: {it['title']} =====")
        parts.append(it["issue_text"])
        parts.append(f"--- candidate rationale (stage 1): {it['stage1_rationale']}")
        excerpt = it["diff_excerpt"] or "(no diff hunks in this PR reference the mechanisms this issue names)"
        parts.append("--- diff excerpt (lines this PR changed that mention the issue's terms) ---")
        parts.append(excerpt)
        parts.append("")
    parts.append(
        'Return ONLY {"verifications": [...]}, one entry per issue above, using the '
        "exact issue numbers."
    )
    return "\n".join(parts)


def parse_verifications(raw: str) -> list[dict[str, Any]]:
    """Extract the verifications list from a stage-2 model response."""
    raw = (raw or "").strip()
    if not raw:
        return []

    def _coerce(obj: Any) -> list[dict[str, Any]] | None:
        if isinstance(obj, dict) and isinstance(obj.get("verifications"), list):
            return obj["verifications"]
        if isinstance(obj, dict) and isinstance(obj.get("candidates"), list):
            return obj["candidates"]
        if isinstance(obj, list):
            return obj
        return None

    for chunk in (raw, raw[raw.find("{"): raw.rfind("}") + 1] if "{" in raw else ""):
        if not chunk:
            continue
        try:
            coerced = _coerce(json.loads(chunk))
            if coerced is not None:
                return coerced
        except json.JSONDecodeError:
            continue
    return []


# --------------------------------------------------------------------------- #
# Inference (GitHub Models REST API)
# --------------------------------------------------------------------------- #
def call_model(
    token: str, model: str, system_prompt: str, user_prompt: str,
    max_tokens: int, temperature: float, retries: int = 3,
    reasoning_effort: str = "",
) -> str:
    body: dict[str, Any] = {
        "model": model,
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_prompt},
        ],
        "response_format": {"type": "json_object"},
    }
    if reasoning_effort:
        # Reasoning models (o-series, gpt-5, deepseek-r1, ...) use max_completion_tokens
        # plus a reasoning_effort knob, and reject a custom temperature.
        body["max_completion_tokens"] = max_tokens
        body["reasoning_effort"] = reasoning_effort
    else:
        body["max_tokens"] = max_tokens
        body["temperature"] = temperature
    payload = json.dumps(body).encode("utf-8")

    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/vnd.github+json",
        "Content-Type": "application/json",
        "X-GitHub-Api-Version": MODELS_API_VERSION,
    }

    last_error = ""
    for attempt in range(1, retries + 1):
        request = urllib.request.Request(MODELS_API_URL, data=payload, headers=headers, method="POST")
        try:
            with urllib.request.urlopen(request, timeout=180) as response:
                data = json.loads(response.read().decode("utf-8"))
            return data["choices"][0]["message"]["content"]
        except urllib.error.HTTPError as exc:
            body = exc.read().decode("utf-8", "replace")
            last_error = f"HTTP {exc.code}: {body[:500]}"
            # Retry on rate limit / transient server errors.
            if exc.code in (429, 500, 502, 503, 504) and attempt < retries:
                wait = exc.headers.get("Retry-After")
                delay = int(wait) if (wait and wait.isdigit()) else min(2 ** attempt, 30)
                delay = min(delay, 60)  # never stall a batch for too long
                _log(f"Inference attempt {attempt} failed ({last_error}); retrying in {delay}s.")
                time.sleep(delay)
                continue
            raise RuntimeError(f"GitHub Models request failed: {last_error}") from exc
        except (urllib.error.URLError, KeyError, IndexError, TypeError,
                TimeoutError, json.JSONDecodeError) as exc:
            last_error = str(exc)
            if attempt < retries:
                delay = min(2 ** attempt, 30)
                _log(f"Inference attempt {attempt} errored ({last_error}); retrying in {delay}s.")
                time.sleep(delay)
                continue
            raise RuntimeError(f"GitHub Models request failed: {last_error}") from exc
    raise RuntimeError(f"GitHub Models request failed: {last_error}")


def parse_candidates(raw: str) -> list[dict[str, Any]]:
    """Tolerantly extract a candidates list from a model response."""
    raw = (raw or "").strip()
    if not raw:
        return []

    def _coerce(obj: Any) -> list[dict[str, Any]] | None:
        if isinstance(obj, dict) and isinstance(obj.get("candidates"), list):
            return obj["candidates"]
        if isinstance(obj, list):
            return obj
        return None

    try:
        coerced = _coerce(json.loads(raw))
        if coerced is not None:
            return coerced
    except json.JSONDecodeError:
        pass

    if "```" in raw:
        start = raw.find("```")
        body = raw[start + 3:]
        if body[:4].lower() == "json":
            body = body[4:]
        end = body.find("```")
        if end != -1:
            body = body[:end]
        try:
            coerced = _coerce(json.loads(body.strip()))
            if coerced is not None:
                return coerced
        except json.JSONDecodeError:
            pass

    first, last = raw.find("{"), raw.rfind("}")
    if first != -1 and last > first:
        try:
            coerced = _coerce(json.loads(raw[first:last + 1]))
            if coerced is not None:
                return coerced
        except json.JSONDecodeError:
            pass
    return []


# --------------------------------------------------------------------------- #
# Render
# --------------------------------------------------------------------------- #
def _cell(text: Any, limit: int = 400) -> str:
    text = "" if text is None else str(text)
    text = text.replace("|", "\\|").replace("\r", " ").replace("\n", "<br>")
    return _truncate(text, limit, " ...")


def _verdict_rank(verdict: str) -> int:
    return {"CONFIRMED": 0, "PARTIAL": 1, "UNVERIFIED": 2}.get(verdict, 3)


def render_markdown(
    meta: dict[str, Any], shortlist: list[dict[str, Any]], filtered: list[dict[str, Any]],
    model: str, min_confidence: int, stage1_errors: list[str], stage2_errors: list[str],
    dropped_invalid: int, verify_enabled: bool,
) -> str:
    repo = meta.get("target_repo", "")

    show = [c for c in shortlist if c.get("confidence", 0) >= min_confidence]
    show.sort(key=lambda c: (_verdict_rank(c.get("verdict", "")), -c.get("confidence", 0)))

    out: list[str] = []
    out.append("# Issue triage — candidates for human review")
    out.append("")
    out.append(
        "> **Review required.** This is an automated shortlist of OPEN issues that the "
        "merged change *might* resolve. It does **not** close anything. A human must "
        "verify each candidate before closing."
    )
    out.append("")
    out.append(
        f"**Analyzed merge:** [PR #{meta.get('pr_number', '')}]"
        f"({meta.get('pr_url', '')}) — {meta.get('pr_title', '')}  "
    )
    out.append(f"**Repository:** `{repo}`  ")
    out.append(f"**Merged at:** {meta.get('pr_merged_at', '')}  ")
    pipeline = "two-stage (generate, ground, verify)" if verify_enabled else "single-stage (generate only)"
    out.append(
        f"**Open issues considered:** {meta.get('issue_count', 0)} | "
        f"**Model:** `{model}` | **Pipeline:** {pipeline} | **Min confidence:** {min_confidence}"
    )
    out.append("")

    if stage1_errors or stage2_errors:
        out.append(
            f"> **Caution:** {len(stage1_errors)} stage-1 and {len(stage2_errors)} stage-2 "
            "batch(es) hit errors (often GitHub Models rate/quota limits). The shortlist may "
            "be incomplete and some rows may be left UNVERIFIED. See `raw_responses.json` in "
            "the artifact."
        )
        out.append("")

    if not show:
        out.append(
            "**No candidate issues found** after grounding and verification (at the "
            "configured confidence threshold). Nothing to review."
        )
    else:
        out.append(f"## {len(show)} candidate issue(s)")
        out.append("")
        out.append("| Issue | Verdict | Confidence | Title | Why it might be closed | Evidence (diff/code) |")
        out.append("| ----- | ------- | ---------- | ----- | ---------------------- | -------------------- |")
        for cand in show:
            link = f"[#{cand['number']}](https://github.com/{repo}/issues/{cand['number']})"
            out.append(
                f"| {link} | {cand.get('verdict', 'UNVERIFIED')} | {cand['confidence']} | "
                f"{_cell(cand.get('title', ''), 100)} | {_cell(cand.get('rationale', ''))} | "
                f"{_cell(cand.get('evidence', ''))} |"
            )
        out.append("")
        out.append(
            "_Verdict legend: **CONFIRMED** = the diff implements a fix for the issue's "
            "specific problem; **PARTIAL** = related but incomplete; **UNVERIFIED** = the "
            "diff-aware check could not run (e.g. rate limit). Always confirm manually before "
            "closing — add a verified `Closes #N` only after review._"
        )

    if filtered:
        out.append("")
        out.append(
            f"<details><summary>{len(filtered)} candidate(s) filtered out — shown for "
            "transparency</summary>"
        )
        out.append("")
        out.append("| Issue | Why it was filtered |")
        out.append("| ----- | ------------------- |")
        for cand in sorted(filtered, key=lambda c: c["number"]):
            link = f"[#{cand['number']}](https://github.com/{repo}/issues/{cand['number']})"
            out.append(f"| {link} | {_cell(cand.get('filter_reason', ''), 300)} |")
        out.append("")
        out.append("</details>")

    if dropped_invalid:
        out.append("")
        out.append(
            f"_Note: {dropped_invalid} returned issue reference(s) were not in the "
            "open-issue list and were ignored._"
        )
    return "\n".join(out)


# --------------------------------------------------------------------------- #
# Orchestration
# --------------------------------------------------------------------------- #
def cmd_run(args: argparse.Namespace) -> int:
    repo = args.target_repo
    out_dir = args.output_dir
    os.makedirs(out_dir, exist_ok=True)

    # Reasoning models (gpt-5, o3, deepseek-r1, ...) have a tighter input cap on
    # GitHub Models (~4000 tokens vs ~8000 for gpt-4o) and spend output budget on
    # hidden reasoning. When --reasoning-effort is set, default to smaller per-request
    # budgets and a larger completion allowance unless the caller overrode them.
    reasoning = bool(args.reasoning_effort)
    if args.max_request_chars is None:
        args.max_request_chars = 11000 if reasoning else 18000
    if args.max_changeset_chars is None:
        args.max_changeset_chars = 2800 if reasoning else 9000
    if args.max_files_in_prompt is None:
        args.max_files_in_prompt = 30 if reasoning else 80
    if args.max_issue_body_chars is None:
        args.max_issue_body_chars = 220 if reasoning else 500
    if args.max_pr_body_chars is None:
        args.max_pr_body_chars = 1000 if reasoning else 2000
    if args.max_completion_tokens is None:
        args.max_completion_tokens = 4000 if reasoning else 2000

    limits = {
        "pr_body": args.max_pr_body_chars,
        "changeset": args.max_changeset_chars,
        "files_in_prompt": args.max_files_in_prompt,
    }

    base_branch = resolve_default_branch(repo)
    pr_number = resolve_pr_number(repo, args.pr_number, base_branch)
    _log(f"Analyzing {repo} PR #{pr_number} (base branch: {base_branch})")

    pr = fetch_pr(repo, pr_number)
    if not pr.get("mergedAt"):
        raise RuntimeError(
            f"PR #{pr_number} in {repo} is not merged. This workflow analyzes merged "
            "pull requests only; pass a merged PR number or leave it blank."
        )
    diff = fetch_diff(repo, pr_number)
    issues = fetch_open_issues(repo, args.max_issues)
    _log(f"Fetched {len(issues)} open issue(s); PR touches {len(pr.get('files') or [])} file(s).")

    changeset_md = build_changeset_md(pr, limits)

    # Persist inputs as artifacts for human inspection / debugging.
    with open(os.path.join(out_dir, "changeset.md"), "w", encoding="utf-8") as handle:
        handle.write(changeset_md)
    with open(os.path.join(out_dir, "issues.json"), "w", encoding="utf-8") as handle:
        json.dump(issues, handle, indent=2)
    if diff:
        with open(os.path.join(out_dir, "pr.diff"), "w", encoding="utf-8") as handle:
            handle.write(diff)

    meta = {
        "target_repo": repo,
        "base_branch": base_branch,
        "pr_number": pr_number,
        "pr_title": pr.get("title", ""),
        "pr_url": pr.get("url", ""),
        "pr_merged_at": pr.get("mergedAt", ""),
        "issue_count": len(issues),
        "valid_issue_numbers": sorted(int(i["number"]) for i in issues),
    }
    with open(os.path.join(out_dir, "meta.json"), "w", encoding="utf-8") as handle:
        json.dump(meta, handle, indent=2)

    fixed_prefix = len(SYSTEM_PROMPT) + len(changeset_md) + 600
    batches = list(
        iter_issue_batches(
            issues, fixed_prefix, args.max_request_chars, args.max_issue_body_chars
        )
    )
    _log(f"Split {len(issues)} issue(s) into {len(batches)} batch(es).")

    token = _resolve_token()
    if not token and not args.dry_run:
        raise RuntimeError(
            "No token available for GitHub Models. Set GITHUB_TOKEN / GH_TOKEN "
            "(the workflow provides github.token with `models: read`)."
        )

    # Stage-2 verification can use a different (advanced) model than stage 1. This
    # supports a hybrid setup: a cheap, high-quota model (e.g. gpt-4o) generates
    # candidates over all issues, and a reasoning model (e.g. gpt-5) verifies the
    # short list of survivors against the diff — keeping total reasoning-model calls
    # within the tight daily quota.
    stage2_model = args.verify_model or args.model
    stage2_reasoning = args.verify_reasoning_effort if args.verify_model else args.reasoning_effort
    stage2_is_reasoning = bool(stage2_reasoning)
    stage2_request_chars = 11000 if stage2_is_reasoning else args.max_request_chars
    stage2_max_completion = 4000 if stage2_is_reasoning else args.max_completion_tokens

    # Pace only before reasoning-model calls (those carry the tight 1/minute limit).
    reasoning_calls = {"n": 0}

    def model_call(model: str, reasoning_effort: str, max_completion: int,
                   system_prompt: str, user_prompt: str,
                   temperature: float | None = None) -> str:
        if reasoning_effort and args.request_spacing_seconds > 0 and reasoning_calls["n"] > 0:
            _log(f"Pacing {args.request_spacing_seconds}s before next reasoning-model "
                 "call (per-minute rate limit)...")
            time.sleep(args.request_spacing_seconds)
        if reasoning_effort:
            reasoning_calls["n"] += 1
        return call_model(
            token, model, system_prompt, user_prompt, max_completion,
            args.temperature if temperature is None else temperature,
            reasoning_effort=reasoning_effort,
        )

    raw_responses: list[dict[str, Any]] = []
    issues_by_num = {int(i["number"]): i for i in issues}

    # ---- Stage 1: broad candidate generation over all open issues ----
    # Optionally run multiple independent passes (self-consistency). A single pass
    # of a cheap model has noisy recall (it can miss a real fix run-to-run); unioning
    # a few diversified passes stabilises which issues surface. A slightly higher
    # temperature diversifies passes (non-reasoning models only).
    passes = max(1, args.stage1_passes)
    stage1_temp = args.stage1_temperature if passes > 1 else None
    stage1_errors: list[str] = []
    stage1_candidates: list[dict[str, Any]] = []
    for pass_no in range(1, passes + 1):
        for index, batch in enumerate(batches, start=1):
            issues_md = "\n".join(issue_block(issue, args.max_issue_body_chars) for issue in batch)
            user_prompt = build_user_prompt(changeset_md, issues_md, len(batch))
            if args.dry_run:
                if pass_no == 1:
                    _log(f"[dry-run] stage1 batch {index}/{len(batches)}: {len(batch)} issue(s), "
                         f"~{len(SYSTEM_PROMPT) + len(user_prompt)} chars")
                    raw_responses.append({"stage": 1, "pass": pass_no, "batch": index,
                                          "issues": [i["number"] for i in batch],
                                          "prompt_chars": len(SYSTEM_PROMPT) + len(user_prompt)})
                continue
            label = f"pass {pass_no}/{passes} " if passes > 1 else ""
            try:
                content = model_call(args.model, args.reasoning_effort,
                                     args.max_completion_tokens, SYSTEM_PROMPT, user_prompt,
                                     temperature=stage1_temp)
                candidates = parse_candidates(content)
                if not candidates and '"candidates"' not in content:
                    stage1_errors.append(f"stage1 {label}batch {index}: unexpected response shape")
                    _log(f"Stage 1 {label}batch {index}/{len(batches)}: unexpected response shape.")
                stage1_candidates.extend(candidates)
                raw_responses.append({"stage": 1, "pass": pass_no, "batch": index,
                                      "issues": [i["number"] for i in batch], "response": content})
                _log(f"Stage 1 {label}batch {index}/{len(batches)}: {len(batch)} issue(s) -> "
                     f"{len(candidates)} candidate(s).")
            except Exception as exc:  # noqa: BLE001 - keep going; report at the end
                stage1_errors.append(f"stage1 {label}batch {index}: {exc}")
                raw_responses.append({"stage": 1, "pass": pass_no, "batch": index,
                                      "issues": [i["number"] for i in batch], "error": str(exc)})
                _log(f"Stage 1 {label}batch {index}/{len(batches)} failed: {exc}")

    # Normalize + de-duplicate stage-1 candidates against the real open-issue set.
    stage1_by_num: dict[int, dict[str, Any]] = {}
    dropped_invalid = 0
    for cand in stage1_candidates:
        if not isinstance(cand, dict):
            continue
        try:
            number = int(cand.get("issue_number"))
        except (TypeError, ValueError):
            continue
        if number not in issues_by_num:
            dropped_invalid += 1
            continue
        try:
            confidence = int(cand.get("confidence", 0))
        except (TypeError, ValueError):
            confidence = 0
        prev = stage1_by_num.get(number)
        if prev and prev["confidence"] >= confidence:
            continue
        stage1_by_num[number] = {
            "number": number,
            "title": cand.get("title", "") or issues_by_num[number].get("title", ""),
            "confidence": confidence,
            "rationale": cand.get("rationale", ""),
            "evidence": cand.get("supporting_evidence", ""),
        }

    # ---- Stage 1.5: deterministic mechanism-grounding gate ----
    # Drop candidates whose issue names several specific identifiers/error-strings,
    # none of which appear anywhere in the PR diff (a strong "wrong subsystem" signal).
    diff_lower = (diff or "").lower()
    survivors: list[dict[str, Any]] = []
    filtered: list[dict[str, Any]] = []
    for number, cand in stage1_by_num.items():
        signals = extract_issue_signals(issues_by_num[number])
        grounding = grounding_for_issue(signals, diff_lower)
        cand["signals"] = signals
        cand["grounding"] = grounding
        if (diff and grounding["strong_signal_count"] >= args.grounding_min_tokens
                and grounding["hits"] == 0):
            cand["filter_reason"] = (
                f"no mechanism grounding — none of the {grounding['strong_signal_count']} "
                "specific terms this issue names appear in the PR diff (likely a same-theme, "
                "different-bug match)"
            )
            filtered.append(cand)
        else:
            survivors.append(cand)
    survivors.sort(key=lambda c: c["confidence"], reverse=True)
    if not args.dry_run:
        _log(f"Grounding gate: kept {len(survivors)}, filtered {len(filtered)} "
             "(zero mechanism grounding).")

    # ---- Stage 2: diff-aware verification of survivors ----
    stage2_errors: list[str] = []
    verify_enabled = (not args.no_verify) and bool(diff)
    do_stage2 = verify_enabled and survivors and not args.dry_run
    if do_stage2:
        items = []
        for cand in survivors:
            issue = issues_by_num[cand["number"]]
            items.append({
                "number": cand["number"],
                "title": issue.get("title", ""),
                "issue_text": _truncate((issue.get("body") or "").strip(), 900, " ...") or "(no description)",
                "stage1_rationale": cand.get("rationale", ""),
                "diff_excerpt": extract_focused_diff(diff, cand["signals"], args.max_slice_chars),
            })
        budget = max(stage2_request_chars - len(STAGE2_SYSTEM_PROMPT) - 600, 3000)
        s2_batches: list[list[dict[str, Any]]] = []
        cur: list[dict[str, Any]] = []
        cur_len = 0
        for it in items:
            ilen = len(it["issue_text"]) + len(it["diff_excerpt"]) + len(it["title"]) + 200
            if cur and cur_len + ilen > budget:
                s2_batches.append(cur)
                cur, cur_len = [], 0
            cur.append(it)
            cur_len += ilen
        if cur:
            s2_batches.append(cur)

        verdict_by_num: dict[int, dict[str, Any]] = {}
        for bi in s2_batches:
            try:
                content = model_call(stage2_model, stage2_reasoning, stage2_max_completion,
                                     STAGE2_SYSTEM_PROMPT, build_stage2_prompt(bi))
                verdicts = parse_verifications(content)
                raw_responses.append({"stage": 2, "issues": [b["number"] for b in bi],
                                      "response": content})
                for v in verdicts:
                    if not isinstance(v, dict):
                        continue
                    key = str(v.get("issue_number", "")).strip().lstrip("#")
                    if key.isdigit():
                        verdict_by_num[int(key)] = v
                _log(f"Stage 2 ({stage2_model}): verified {len(bi)} candidate(s) -> "
                     f"{len(verdicts)} verdict(s).")
            except Exception as exc:  # noqa: BLE001 - degrade gracefully
                stage2_errors.append(f"stage2: {exc}")
                raw_responses.append({"stage": 2, "issues": [b["number"] for b in bi],
                                      "error": str(exc)})
                _log(f"Stage 2 batch failed: {exc}")

        for cand in survivors:
            v = verdict_by_num.get(cand["number"])
            if not v:
                cand["verdict"] = "UNVERIFIED"  # stage-2 unavailable (e.g. quota); keep, flagged
                continue
            verdict = str(v.get("verdict", "")).upper().replace("-", "_")
            cand["verdict"] = verdict if verdict in ("CONFIRMED", "PARTIAL", "FALSE_POSITIVE") else "UNVERIFIED"
            try:
                cand["confidence"] = int(v.get("confidence", cand["confidence"]))
            except (TypeError, ValueError):
                pass
            cand["rationale"] = v.get("rationale") or cand["rationale"]
            cand["evidence"] = v.get("evidence") or cand["evidence"]

        for cand in survivors:
            if cand.get("verdict") == "FALSE_POSITIVE":
                cand["filter_reason"] = (
                    "stage-2 diff check: touches the same area but does not fix the issue's "
                    "specific problem"
                )
                filtered.append(cand)
        shortlist = [c for c in survivors if c.get("verdict") != "FALSE_POSITIVE"]
    else:
        for cand in survivors:
            cand.setdefault("verdict", "UNVERIFIED")
        shortlist = survivors

    with open(os.path.join(out_dir, "raw_responses.json"), "w", encoding="utf-8") as handle:
        json.dump(raw_responses, handle, indent=2)
    with open(os.path.join(out_dir, "candidates.json"), "w", encoding="utf-8") as handle:
        json.dump({"shortlist": shortlist, "filtered": filtered}, handle, indent=2, default=str)

    model_label = args.model
    if verify_enabled and stage2_model != args.model:
        model_label = f"{args.model} (stage 1) + {stage2_model} (verify)"
    markdown = render_markdown(
        meta, shortlist, filtered, model_label, args.min_confidence,
        stage1_errors, stage2_errors, dropped_invalid, verify_enabled,
    )
    with open(os.path.join(out_dir, "summary.md"), "w", encoding="utf-8") as handle:
        handle.write(markdown + "\n")

    step_summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if step_summary:
        with open(step_summary, "a", encoding="utf-8") as handle:
            handle.write(markdown + "\n")

    print(markdown)

    _emit_outputs(
        {
            "pr_number": str(pr_number),
            "pr_url": pr.get("url", ""),
            "issue_count": str(len(issues)),
            "batch_count": str(len(batches)),
            "candidate_count": str(len([c for c in shortlist if c.get("confidence", 0) >= args.min_confidence])),
            "filtered_count": str(len(filtered)),
            "error_count": str(len(stage1_errors) + len(stage2_errors)),
        }
    )

    # Hard-fail only if every stage-1 batch failed (no candidates to work with).
    # Stage-2 / grounding issues degrade gracefully (partial results stay useful).
    if stage1_errors and len(stage1_errors) >= len(batches) * passes and not args.dry_run:
        raise RuntimeError(f"All stage-1 inference batch(es) failed; see log.")
    return 0


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #
def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    run = sub.add_parser("run", help="Analyze a merged PR against open issues.")
    run.add_argument("--target-repo", required=True, help="owner/name of the repo to analyze.")
    run.add_argument("--pr-number", default="", help="PR to analyze; default = latest merged PR.")
    run.add_argument("--output-dir", default="triage", help="Directory for prompt/output artifacts.")
    run.add_argument("--model", default="openai/gpt-4o", help="GitHub Models model id.")
    run.add_argument("--min-confidence", type=int, default=30)
    run.add_argument("--max-issues", type=int, default=300)
    run.add_argument("--max-request-chars", type=int, default=None,
                     help="Approx char budget per request. Default: 18000 (8k-token models) "
                          "or 11000 when --reasoning-effort is set (4k-token models).")
    run.add_argument("--max-issue-body-chars", type=int, default=None)
    run.add_argument("--max-pr-body-chars", type=int, default=None)
    run.add_argument("--max-changeset-chars", type=int, default=None)
    run.add_argument("--max-files-in-prompt", type=int, default=None)
    run.add_argument("--max-completion-tokens", type=int, default=None)
    run.add_argument("--temperature", type=float, default=0.1)
    run.add_argument("--reasoning-effort", default="",
                     help="For reasoning models (gpt-5, o3, deepseek-r1): minimal|low|medium|high. "
                          "When set, temperature is omitted and max_completion_tokens is used.")
    run.add_argument("--verify-model", default="",
                     help="Optional separate model for stage-2 verification (e.g. openai/gpt-5). "
                          "Defaults to --model. Enables a hybrid cheap-generate / advanced-verify run.")
    run.add_argument("--verify-reasoning-effort", default="",
                     help="Reasoning effort for the stage-2 verify model (when --verify-model is set).")
    run.add_argument("--request-spacing-seconds", type=int, default=0,
                     help="Sleep between batches to respect tight per-minute rate limits "
                          "(e.g. 62 for gpt-5's 1 request/minute limit).")
    run.add_argument("--no-verify", action="store_true",
                     help="Skip the stage-2 diff-aware verification (candidate generation only).")
    run.add_argument("--stage1-passes", type=int, default=1,
                     help="Run stage-1 candidate generation this many times and union the "
                          "results (self-consistency) to stabilise recall. Recommended 2 with a "
                          "cheap stage-1 model.")
    run.add_argument("--stage1-temperature", type=float, default=0.5,
                     help="Sampling temperature used for stage-1 passes when --stage1-passes > 1 "
                          "(diversifies passes; ignored by reasoning models).")
    run.add_argument("--grounding-min-tokens", type=int, default=3,
                     help="Drop a candidate when its issue names at least this many specific "
                          "identifiers/error-strings yet none appear in the PR diff.")
    run.add_argument("--max-slice-chars", type=int, default=2800,
                     help="Max characters of focused diff excerpt sent per candidate in stage 2.")
    run.add_argument("--dry-run", action="store_true",
                     help="Gather and batch but skip the model calls (no token needed).")
    run.set_defaults(func=cmd_run)

    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
