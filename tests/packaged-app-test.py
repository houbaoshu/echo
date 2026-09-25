"""Audit an already-built App across relocation, signatures and process shutdown."""
import argparse
import os
from pathlib import Path
import selectors
import shutil
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--fixture-server", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    source = args.app.resolve(strict=True)
    fixture = args.fixture_server.resolve(strict=True)
    args.output.mkdir(parents=True, exist_ok=True)
    root = Path(tempfile.mkdtemp(prefix="packaged-", dir=args.output.resolve()))
    app = root / "relocated with spaces" / "Echo.app"
    app.parent.mkdir()
    shutil.copytree(source, app)
    cwd = root / "empty-cwd"
    cwd.mkdir()
    artifacts = root / "artifacts"
    executable = app / "Contents/MacOS/Echo"
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    dependencies = subprocess.check_output(["otool", "-L", str(executable)], text=True)
    assert all(line.strip().startswith(("/System/Library/", "/usr/lib/"))
               for line in dependencies.splitlines()[1:]), dependencies
    (root / "libraries.txt").write_text(dependencies)
    with (root / "fixture.log").open("w") as errors:
        server = subprocess.Popen([str(fixture)], cwd=cwd, stdout=subprocess.PIPE,
                                  stderr=errors, text=True)
        try:
            with selectors.DefaultSelector() as selector:
                selector.register(server.stdout, selectors.EVENT_READ)
                assert selector.select(timeout=5), "Fixture startup timed out"
            port = int(server.stdout.readline().strip())
            with (root / "app.log").open("w") as log:
                result = subprocess.run([str(executable), "--acceptance-test",
                                         f"http://127.0.0.1:{port}", str(artifacts)],
                                        cwd=cwd, stdout=log, stderr=subprocess.STDOUT, timeout=40)
            output = (root / "app.log").read_text()
            assert result.returncode == 0, f"App failed: {result.returncode}; see {root / 'app.log'}"
            assert "relocated bundle loaded pet and default prompt from empty cwd" in output
            assert "AppKit termination acknowledged Rust cleanup" in output
            pids = list(artifacts.glob("process-audit/*.pid"))
            assert len(pids) == 2, "The shell/child exit scenario did not start"
            for file in pids:
                try:
                    os.kill(int(file.read_text().strip()), 0)
                except ProcessLookupError:
                    continue
                raise AssertionError(f"Process survived AppKit termination: {file.name}")
            assert list(cwd.iterdir()) == [], "App or fixture wrote into its empty working directory"
            print("PASS: signed relocated App, bundled resources, system libraries, normal exit, no surviving shell/child")
        finally:
            server.terminate()
            try:
                code = server.wait(timeout=6)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait()
                raise AssertionError("Fixture did not finish socket cleanup")
            finally:
                print(f"Evidence: {root}")
            assert code == 0, f"Fixture failed: {code}; see {root / 'fixture.log'}"


if __name__ == "__main__":
    main()
