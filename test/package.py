#!/usr/bin/env python3
"""Exercise the real package manager offline: YA=/path/to/ya python3 test/package.py."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile


repo = Path(__file__).resolve().parents[1]
ya = shutil.which(os.environ.get("YA", "ya"))
if ya is None:
    raise SystemExit("Install Yazi or set YA to the ya executable")

with tempfile.TemporaryDirectory(prefix="bunny-package-") as work:
    root = Path(work)
    source = root / "source"
    config = root / "config"
    shutil.copytree(repo, source, symlinks=True, ignore=shutil.ignore_patterns(".git", "__pycache__"))

    def git(*args):
        subprocess.run(["git", *args], cwd=source, check=True, stdout=subprocess.DEVNULL)

    git("init", "-b", "main")
    git("add", ".")
    git("-c", "user.name=Bunny test", "-c", "user.email=test@example.invalid",
        "-c", "commit.gpgsign=false", "commit", "-m", "Test package snapshot")

    # Redirect only this subprocess's package clone to the local snapshot.
    env = os.environ | {
        "YAZI_CONFIG_HOME": str(config),
        "XDG_CACHE_HOME": str(root / "cache"),
        "GIT_CONFIG_COUNT": "1",
        "GIT_CONFIG_KEY_0": f"url.{source.as_uri()}.insteadOf",
        "GIT_CONFIG_VALUE_0": "https://github.com/stexus/bunny.yazi.git",
    }

    def package(*args):
        subprocess.run([ya, "pkg", *args], env=env, check=True)
        installed = config / "plugins/bunny.yazi/main.lua"
        assert installed.read_bytes() == (repo / "main.lua").read_bytes()

    package("add", "stexus/bunny")
    package("upgrade")
    # Older package caches can contain native symlinks, unlike a fresh ya clone.
    caches = list((root / "cache/yazi/packages").iterdir())
    assert len(caches) == 1
    shutil.rmtree(caches[0])
    subprocess.run(
        ["git", "clone", "-c", "core.symlinks=true", str(source), str(caches[0])],
        check=True,
    )
    package("upgrade")
    # A locked install must also deploy successfully into an empty plugins directory.
    shutil.rmtree(config / "plugins")
    package("install")
    print("Package add, upgrade, and locked install passed")
