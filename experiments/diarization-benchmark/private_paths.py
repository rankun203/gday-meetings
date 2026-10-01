"""Keep private outputs outside this checkout or in its ignored tmp directory."""
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def private_output(path):
    output = Path(path).resolve()
    if output == ROOT or ROOT in output.parents:
        temporary = ROOT / 'tmp'
        if temporary not in output.parents:
            raise ValueError('Private output must be under ignored tmp/ or outside the worktree')
        relative = str(output.relative_to(ROOT))
        # Ignore matching must not consult the index using filename glob syntax;
        # tracking is checked separately with literal pathspecs below.
        ignored = subprocess.run(['git', 'check-ignore', '--no-index', '-q', '--', relative], cwd=ROOT).returncode == 0
        tracked = subprocess.run(['git', '--literal-pathspecs', 'ls-files', '--', relative], cwd=ROOT, capture_output=True, text=True, check=True).stdout
        if not ignored or tracked:
            raise ValueError('Private output must be ignored and untracked')
    return output
