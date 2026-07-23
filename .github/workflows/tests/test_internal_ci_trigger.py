"""Contract tests for the internal CI trigger workflow."""

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml


WORKFLOW = Path(__file__).resolve().parents[1] / "internal-ci-trigger.yml"
ADO_PIPELINE = next(
    (
        parent / ".pipelines/oss_documentdb_external_ci.yml"
        for parent in WORKFLOW.parents
        if (parent / ".pipelines/oss_documentdb_external_ci.yml").is_file()
    ),
    None,
)
MALICIOUS_BRANCH = 'x";printf${IFS}%s${IFS}"$MS_WEBHOOK_SECRET";#'
APP_TOKEN_ACTION_SHA = "bcd2ba49218906704ab6c1aa796996da409d3eb1"


def workflow_step(name: str) -> dict[str, object]:
    workflow = yaml.safe_load(WORKFLOW.read_text())
    steps = workflow["jobs"]["trigger-internal-ci"]["steps"]
    return next(step for step in steps if step["name"] == name)


def write_executable(path: Path, content: str) -> None:
    path.write_text(content)
    path.chmod(0o755)


class InternalCiTriggerTests(unittest.TestCase):
    def run_pr_details_step(
        self, pr_data: dict[str, object]
    ) -> tuple[subprocess.CompletedProcess[str], str]:
        script = workflow_step("Get PR details and pinned SHA")["run"]
        script = script.replace("${{ github.event.issue.number }}", "42")
        script = script.replace("${{ github.repository }}", "documentdb/documentdb")

        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = Path(temp_dir)
            output_path = temp_path / "github-output"
            bin_path = temp_path / "bin"
            bin_path.mkdir()
            write_executable(
                bin_path / "gh",
                "#!/usr/bin/env bash\n"
                "set -euo pipefail\n"
                "printf '%s\\n' \"$MOCK_PR_DATA\"\n",
            )

            env = os.environ.copy()
            env["PATH"] = f"{bin_path}{os.pathsep}{env['PATH']}"
            env["GITHUB_OUTPUT"] = str(output_path)
            env["MOCK_PR_DATA"] = json.dumps(pr_data)

            result = subprocess.run(
                ["bash", "-c", f"set -euo pipefail\n{script}"],
                env=env,
                text=True,
                capture_output=True,
            )
            outputs = output_path.read_text() if output_path.exists() else ""
            return result, outputs

    def test_accepts_same_repository_and_fork_prs(self):
        for head_repo in ("documentdb/documentdb", "contributor/documentdb"):
            with self.subTest(head_repo=head_repo):
                result, outputs = self.run_pr_details_step(
                    {
                        "sha": "a" * 40,
                        "branch": "users/example/topic",
                        "head_repo": head_repo,
                        "base_repo": "documentdb/documentdb",
                        "base_ref": "main",
                        "author": "contributor-login",
                    }
                )

                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn(f"head_repo={head_repo}\n", outputs)
                self.assertIn("commit_sha=" + "a" * 40 + "\n", outputs)
                self.assertIn("pr_author=contributor-login\n", outputs)

    def test_rejects_deleted_fork(self):
        result, _ = self.run_pr_details_step(
            {
                "sha": "a" * 40,
                "branch": "users/example/topic",
                "head_repo": "",
                "base_repo": "documentdb/documentdb",
                "base_ref": "main",
                "author": "contributor-login",
            }
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("fork may have been deleted", result.stdout)

    def test_rejects_mismatched_base_repository(self):
        result, _ = self.run_pr_details_step(
            {
                "sha": "a" * 40,
                "branch": "users/example/topic",
                "head_repo": "contributor/documentdb",
                "base_repo": "other/documentdb",
                "base_ref": "main",
                "author": "contributor-login",
            }
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not match workflow repository", result.stdout)

    def test_rejects_invalid_head_sha(self):
        result, _ = self.run_pr_details_step(
            {
                "sha": "not-a-sha",
                "branch": "users/example/topic",
                "head_repo": "contributor/documentdb",
                "base_repo": "documentdb/documentdb",
                "base_ref": "main",
                "author": "contributor-login",
            }
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("head SHA is missing or invalid", result.stdout)

    def test_uses_membership_app_token_without_pat_fallback(self):
        token_step = workflow_step("Create Microsoft membership App token")
        membership_step = workflow_step("Check Microsoft organization membership")

        self.assertEqual(
            token_step["uses"],
            f"actions/create-github-app-token@{APP_TOKEN_ACTION_SHA}",
        )
        self.assertEqual(
            token_step["with"]["client-id"],
            "${{ vars.MS_ORG_MEMBERSHIP_APP_CLIENT_ID }}",
        )
        self.assertEqual(
            token_step["with"]["private-key"],
            "${{ secrets.MS_ORG_MEMBERSHIP_APP_PRIVATE_KEY }}",
        )
        self.assertEqual(token_step["with"]["owner"], "microsoft")
        self.assertEqual(token_step["with"]["permission-members"], "read")
        self.assertEqual(
            membership_step["env"]["GH_TOKEN"],
            "${{ steps.membership-app-token.outputs.token }}",
        )
        self.assertNotIn("MS_ORG_READ_TOKEN", WORKFLOW.read_text())

    def test_docs_only_skip_comment_failure_is_non_blocking(self):
        script = workflow_step("Path filter - skip if only irrelevant files changed")[
            "run"
        ]

        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = Path(temp_dir)
            output_path = temp_path / "github-output"
            bin_path = temp_path / "bin"
            bin_path.mkdir()
            write_executable(
                bin_path / "gh",
                "#!/usr/bin/env bash\n"
                "set -euo pipefail\n"
                "if [[ \"$*\" == *'/files'* ]]; then\n"
                "  printf '%s\\n' 'docs/readme.md'\n"
                "  exit 0\n"
                "fi\n"
                "if [[ \"$*\" == *'/comments'* ]]; then\n"
                "  exit 22\n"
                "fi\n"
                "exit 1\n",
            )

            env = os.environ.copy()
            env["PATH"] = f"{bin_path}{os.pathsep}{env['PATH']}"
            env["COMMENT_BODY"] = "/test"
            env["GITHUB_OUTPUT"] = str(output_path)
            env["PR_NUMBER"] = "42"
            env["REPOSITORY"] = "documentdb/documentdb"
            result = subprocess.run(
                ["bash", "-c", f"set -euo pipefail\n{script}"],
                env=env,
                capture_output=True,
                text=True,
            )

            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("skip=true\n", output_path.read_text())
            self.assertIn("explanatory PR comment could not be posted", result.stdout)

    def test_fork_payload_keeps_canonical_repository_as_trust_target(self):
        script = workflow_step("POST webhook to ADO")["run"]
        branch_check = subprocess.run(
            ["git", "check-ref-format", f"refs/heads/{MALICIOUS_BRANCH}"],
            capture_output=True,
            text=True,
        )
        self.assertEqual(branch_check.returncode, 0, branch_check.stderr)

        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = Path(temp_dir)
            payload_path = temp_path / "payload.json"
            bin_path = temp_path / "bin"
            bin_path.mkdir()
            write_executable(
                bin_path / "curl",
                "#!/usr/bin/env python3\n"
                "import os\n"
                "import sys\n"
                "from pathlib import Path\n"
                "args = sys.argv[1:]\n"
                "payload = args[args.index('-d') + 1]\n"
                "Path(os.environ['CAPTURED_PAYLOAD']).write_text(payload)\n"
                "print('200', end='')\n",
            )

            env = os.environ.copy()
            env["PATH"] = f"{bin_path}{os.pathsep}{env['PATH']}"
            env["BASE_BRANCH"] = "main"
            env["CAPTURED_PAYLOAD"] = str(payload_path)
            env["COMMENT_CREATED_AT"] = "2026-07-15T16:00:00Z"
            env["COMMENT_ID"] = "123456789"
            env["COMMENT_URL"] = (
                "https://github.com/documentdb/documentdb/pull/42"
                "#issuecomment-123456789"
            )
            env["COMMIT_SHA"] = "a" * 40
            env["HEAD_REPO"] = "contributor/documentdb"
            env["MS_WEBHOOK_SECRET"] = "test-secret"
            env["PR_AUTHOR"] = "contributor-login"
            env["PR_NUMBER"] = "42"
            env["REPOSITORY"] = "documentdb/documentdb"
            env["SOURCE_BRANCH"] = MALICIOUS_BRANCH
            env["TRIGGERER"] = "maintainer-login"
            result = subprocess.run(
                ["bash", "-c", f"set -euo pipefail\n{script}"],
                env=env,
                text=True,
                capture_output=True,
            )

            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            payload = json.loads(payload_path.read_text())

        self.assertEqual(payload["repository"]["full_name"], "documentdb/documentdb")
        self.assertEqual(
            payload["pull_request"]["base"]["repo"]["full_name"],
            "documentdb/documentdb",
        )
        self.assertEqual(
            payload["pull_request"]["head"]["repo"]["full_name"],
            "contributor/documentdb",
        )
        self.assertEqual(
            payload["pull_request"]["head"]["ref"],
            MALICIOUS_BRANCH,
        )
        self.assertEqual(payload["pull_request"]["user"]["login"], "contributor-login")
        self.assertEqual(payload["comment"]["user"]["login"], "maintainer-login")
        self.assertEqual(payload["triggerer"], "maintainer-login")

    def test_pr_metadata_is_not_interpolated_into_secret_bearing_script(self):
        step = workflow_step("POST webhook to ADO")
        script = step["run"]
        env = step["env"]
        expected_environment = {
            "BASE_BRANCH": "${{ steps.pr.outputs.base_branch }}",
            "COMMIT_SHA": "${{ steps.pr.outputs.commit_sha }}",
            "HEAD_REPO": "${{ steps.pr.outputs.head_repo }}",
            "PR_AUTHOR": "${{ steps.pr.outputs.pr_author }}",
            "PR_NUMBER": "${{ steps.pr.outputs.pr_number }}",
            "SOURCE_BRANCH": "${{ steps.pr.outputs.source_branch }}",
        }

        for name, expression in expected_environment.items():
            with self.subTest(name=name):
                self.assertEqual(env[name], expression)
                self.assertNotIn(expression, script)

    @unittest.skipUnless(ADO_PIPELINE, "ADO pipeline is not present in the OSS mirror")
    def test_ado_uses_base_repository_and_logs_fork_separately(self):
        pipeline = ADO_PIPELINE.read_text()

        self.assertIn(
            "value: ${{ parameters.WebHook.repository.full_name }}",
            pipeline,
        )
        self.assertIn(
            "value: ${{ parameters.WebHook.pull_request.head.repo.full_name }}",
            pipeline,
        )
        self.assertIn("GH_REPO: $(ghRepo)", pipeline)
        self.assertIn("PR_HEAD_REPO: $(prHeadRepo)", pipeline)
        self.assertNotIn("udsmicrosoft/documentdb", pipeline)


if __name__ == "__main__":
    unittest.main()
