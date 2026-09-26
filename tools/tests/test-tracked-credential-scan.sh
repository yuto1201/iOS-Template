#!/usr/bin/env bash
set -euo pipefail

source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" git python3

repo_root=$(cd "$(dirname "$0")/../.." && pwd -P)
if [[ $# -eq 0 ]]; then
  target_root=$repo_root
elif [[ $# -eq 2 && $1 == --root ]]; then
  target_root=$2
else
  echo "usage: $0 [--root REPOSITORY_ROOT]" >&2
  exit 64
fi

python3 - "$target_root" <<'PYTHON'
from pathlib import Path
import re
import subprocess
import sys
import tempfile

token_patterns = (
    re.compile(rb"ghp_[A-Za-z0-9]{12,}"),
    re.compile(rb"github_pat_[A-Za-z0-9_]{12,}"),
    re.compile(rb"glpat-[A-Za-z0-9_-]{12,}"),
    re.compile(rb"xox[baprs]-[A-Za-z0-9-]{12,}"),
    re.compile(rb"(?:^|[^A-Za-z0-9])sk-(?:proj-)?[A-Za-z0-9_-]{12,}"),
    re.compile(rb"sb_secret_[A-Za-z0-9_-]{12,}"),
    re.compile(rb"AIza[0-9A-Za-z_-]{20,}"),
    re.compile(rb"AKIA[0-9A-Z]{16}"),
    re.compile(rb"eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"),
)
private_key = re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----")
password_assignment = re.compile(rb"(?i)password\s*=\s*[^\s\"']{6,}")
dedicated_filename = re.compile(rb"Library/Application Support/iOS-Template/secrets/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+\.(?:p8|pem|key)")
service_role_allowed = {
    ".agents/skills/ios-media-assets/scripts/validate-audio.sh",
    ".agents/skills/ios-media-assets/scripts/validate-transcript.sh",
    ".agents/skills/ios-media-assets/scripts/validate-visual.sh",
    ".agents/skills/supabase-ops/SKILL.md",
    ".agents/skills/supabase-ops/scripts/validate-migrations.sh",
    "docs/security.md",
    "docs/superpowers/plans/2026-08-21-integrations-appstore-release.md",
    "specs/product.md",
    "tools/install-app-icon.sh",
    "tools/tests/fixtures/bootstrap-template/source-identity.json",
    "tools/tests/test-supabase-skill.sh",
    "tools/tests/test-tracked-credential-scan.sh",
    "tools/validate-app-icon.sh",
}
fixture_assignment = b"password=" + b"private-review-value"


def scan(root, allowed):
    paths = subprocess.check_output(["git", "ls-files", "-z"], cwd=root).split(b"\0")
    files = [Path(value.decode()) for value in paths if value]
    violations = []
    service_role_paths = set()
    for path in files:
        try:
            data = (root / path).read_bytes()
        except (OSError, IsADirectoryError):
            continue
        if b"\0" in data:
            continue
        name = path.as_posix()
        if b"service_role" in data:
            service_role_paths.add(name)
        for pattern in token_patterns:
            if pattern.search(data):
                violations.append(f"credential token prefix in {name}")
        if private_key.search(data):
            violations.append(f"private-key header in {name}")
        if name != "tools/tests/test-visual-review-packet.sh" and any(
            match.group(0) != fixture_assignment or name != "tools/tests/test-appstore-preparation.sh"
            for match in password_assignment.finditer(data)
        ):
            violations.append(f"password assignment in {name}")
        if dedicated_filename.search(data):
            violations.append(f"dedicated secret filename in {name}")
    if service_role_paths != allowed:
        violations.append(f"service_role policy occurrence set changed: {sorted(service_role_paths)!r}")
    return violations


def self_test():
    with tempfile.TemporaryDirectory(prefix="tracked-credential-scan-") as directory:
        root = Path(directory)
        subprocess.run(["git", "init", "-q", str(root)], check=True)

        def check(path, content, expected):
            for previous in root.rglob("*"):
                if previous.is_file() and ".git" not in previous.parts:
                    previous.unlink()
            target = root / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(content)
            subprocess.run(["git", "add", "-A"], cwd=root, check=True)
            violations = scan(root, set())
            if expected is None:
                if violations:
                    raise SystemExit(f"tracked credential scan self-test failed for {path}: {violations!r}")
            elif not any(expected in violation for violation in violations):
                raise SystemExit(f"tracked credential scan self-test missed {path}: {violations!r}")

        check("tools/tests/test-appstore-preparation.sh", fixture_assignment, None)
        check("tools/tests/test-appstore-preparation.sh", b"password=" + b"other-review-value", "password assignment in tools/tests/test-appstore-preparation.sh")
        check("tools/tests/other.sh", fixture_assignment, "password assignment in tools/tests/other.sh")
        check("tools/tests/test-visual-review-packet.sh", b"password=" + b"other-review-value", None)
        check("tools/tests/other.sh", b"ghp_" + b"A" * 12, "credential token prefix in tools/tests/other.sh")


self_test()
violations = scan(Path(sys.argv[1]).resolve(), service_role_allowed)
if violations:
    raise SystemExit("tracked credential scan failed: " + "; ".join(violations))
PYTHON
