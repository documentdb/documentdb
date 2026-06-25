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
    # `gh pr list` orders by creation, not merge time, so fetch a window and pick
    # the most recently MERGED one explicitly.
    rows = _gh_json(
        [
            "pr", "list", "--repo", repo,
            "--state", "merged", "--base", base_branch,
            "--limit", "30", "--json", "number,mergedAt",
        ]
    )
    rows = [row for row in rows if row.get("mergedAt")]
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
# Inference (GitHub Models REST API)
# --------------------------------------------------------------------------- #
def call_model(
    token: str, model: str, system_prompt: str, user_prompt: str,
    max_tokens: int, temperature: float, retries: int = 3,
) -> str:
    payload = json.dumps(
        {
            "model": model,
            "messages": [
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": user_prompt},
            ],
            "max_tokens": max_tokens,
            "temperature": temperature,
            "response_format": {"type": "json_object"},
        }
    ).encode("utf-8")

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
            with urllib.request.urlopen(request, timeout=120) as response:
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


def render_markdown(
    meta: dict[str, Any], candidates: list[dict[str, Any]], model: str,
    min_confidence: int, errors: list[str],
) -> str:
    repo = meta.get("target_repo", "")
    valid = set(meta.get("valid_issue_numbers") or [])

    cleaned: dict[int, dict[str, Any]] = {}
    dropped_invalid = 0
    for cand in candidates:
        if not isinstance(cand, dict):
            continue
        try:
            number = int(cand.get("issue_number"))
        except (TypeError, ValueError):
            continue
        if valid and number not in valid:
            dropped_invalid += 1
            continue
        try:
            confidence = int(cand.get("confidence", 0))
        except (TypeError, ValueError):
            confidence = 0
        if confidence < min_confidence:
            continue
        # De-duplicate across batches, keeping the highest-confidence verdict.
        existing = cleaned.get(number)
        if existing and existing["confidence"] >= confidence:
            continue
        cleaned[number] = {
            "number": number,
            "title": cand.get("title", ""),
            "confidence": confidence,
            "rationale": cand.get("rationale", ""),
            "evidence": cand.get("supporting_evidence", ""),
        }
    ordered = sorted(cleaned.values(), key=lambda c: c["confidence"], reverse=True)

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
    out.append(
        f"**Open issues considered:** {meta.get('issue_count', 0)} | "
        f"**Model:** `{model}` | **Min confidence:** {min_confidence}"
    )
    out.append("")

    if errors:
        out.append(
            f"> :warning: {len(errors)} issue batch(es) could not be analyzed; the "
            "shortlist below may be incomplete. See the job log and artifact for details."
        )
        out.append("")

    if not ordered:
        out.append(
            "**No candidate issues found.** The merged change does not appear to close "
            "any of the open issues (at the configured confidence threshold). Nothing "
            "to review."
        )
    else:
        out.append(f"## {len(ordered)} candidate issue(s)")
        out.append("")
        out.append("| Issue | Confidence | Title | Why it might be closed | Supporting evidence |")
        out.append("| ----- | ---------- | ----- | ---------------------- | ------------------- |")
        for cand in ordered:
            link = f"[#{cand['number']}](https://github.com/{repo}/issues/{cand['number']})"
            out.append(
                f"| {link} | {cand['confidence']} | {_cell(cand['title'], 120)} | "
                f"{_cell(cand['rationale'])} | {_cell(cand['evidence'])} |"
            )
        out.append("")
        out.append(
            "_Suggested next step: open each candidate, confirm the merged change fully "
            "resolves it, and close manually (or add a verified `Closes #N` reference) "
            "only after review._"
        )

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

    all_candidates: list[dict[str, Any]] = []
    raw_responses: list[dict[str, Any]] = []
    errors: list[str] = []
    for index, batch in enumerate(batches, start=1):
        issues_md = "\n".join(issue_block(issue, args.max_issue_body_chars) for issue in batch)
        user_prompt = build_user_prompt(changeset_md, issues_md, len(batch))
        if args.dry_run:
            _log(f"[dry-run] batch {index}/{len(batches)}: {len(batch)} issue(s), "
                 f"prompt ~{len(SYSTEM_PROMPT) + len(user_prompt)} chars")
            raw_responses.append({"batch": index, "issues": [i["number"] for i in batch],
                                  "prompt_chars": len(SYSTEM_PROMPT) + len(user_prompt)})
            continue
        try:
            content = call_model(
                token, args.model, SYSTEM_PROMPT, user_prompt,
                args.max_completion_tokens, args.temperature,
            )
            candidates = parse_candidates(content)
            if not candidates and '"candidates"' not in content:
                errors.append(f"batch {index}: response not in the expected JSON shape")
                _log(f"Batch {index}/{len(batches)}: unexpected response shape.")
            all_candidates.extend(candidates)
            raw_responses.append({"batch": index, "issues": [i["number"] for i in batch],
                                  "response": content})
            _log(f"Batch {index}/{len(batches)}: {len(batch)} issue(s) -> "
                 f"{len(candidates)} candidate(s).")
        except Exception as exc:  # noqa: BLE001 - keep going; report at the end
            errors.append(f"batch {index}: {exc}")
            raw_responses.append({"batch": index, "issues": [i["number"] for i in batch],
                                  "error": str(exc)})
            _log(f"Batch {index}/{len(batches)} failed: {exc}")

    with open(os.path.join(out_dir, "raw_responses.json"), "w", encoding="utf-8") as handle:
        json.dump(raw_responses, handle, indent=2)

    markdown = render_markdown(meta, all_candidates, args.model, args.min_confidence, errors)
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
            "candidate_count": str(len({int(c.get("issue_number")) for c in all_candidates
                                        if isinstance(c, dict) and str(c.get("issue_number", "")).isdigit()})),
            "error_count": str(len(errors)),
        }
    )

    # Surface a hard failure only if every batch failed (partial results are fine).
    if errors and len(errors) == len(batches) and not args.dry_run:
        raise RuntimeError(f"All {len(batches)} inference batch(es) failed; see log.")
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
    run.add_argument("--max-request-chars", type=int, default=18000,
                     help="Approx char budget per request (kept well under the 8k-token cap).")
    run.add_argument("--max-issue-body-chars", type=int, default=500)
    run.add_argument("--max-pr-body-chars", type=int, default=2000)
    run.add_argument("--max-changeset-chars", type=int, default=9000)
    run.add_argument("--max-files-in-prompt", type=int, default=80)
    run.add_argument("--max-completion-tokens", type=int, default=2000)
    run.add_argument("--temperature", type=float, default=0.1)
    run.add_argument("--dry-run", action="store_true",
                     help="Gather and batch but skip the model calls (no token needed).")
    run.set_defaults(func=cmd_run)

    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
