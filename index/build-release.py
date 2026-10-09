#!/usr/bin/env python3
"""Package the committed index page with matching Git release metadata."""

import argparse
from datetime import datetime, timezone
import hashlib
import io
import json
from pathlib import Path
import re
import subprocess
import tarfile
import tempfile
import zipfile


ROOT = Path(__file__).resolve().parent.parent


def git(*args):
    return subprocess.check_output(["git", "-C", str(ROOT), *args])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", help="Require the version and HEAD to match this tag")
    args = parser.parse_args()
    if git("status", "--porcelain", "--untracked-files=all").strip():
        raise SystemExit("Commit all source changes before building a release.")

    commit_full = git("rev-parse", "HEAD").decode().strip()
    commit = git("rev-parse", "--short=7", commit_full).decode().strip()
    timestamp = int(git("show", "-s", "--format=%ct", commit_full).decode().strip())
    zip_date = datetime.fromtimestamp(max(timestamp, 315532800), timezone.utc).timetuple()[:6]
    archive = git("archive", "--format=tar", commit_full, "index/index.html")
    with tarfile.open(fileobj=io.BytesIO(archive)) as source:
        html = source.extractfile("index/index.html").read()
    match = re.search(rb'id="release-version">([^<]+)</span>', html)
    if not match:
        raise SystemExit("The committed page has no release version.")
    version = match[1].decode("ascii")
    if not re.fullmatch(r"\d+\.\d+\.\d+(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?", version):
        raise SystemExit("Invalid release version.")
    if args.tag:
        tag_commit = git("rev-parse", args.tag + "^{commit}").decode().strip()
        if args.tag != "v" + version or tag_commit != commit_full:
            raise SystemExit("The tag, page version, and source commit must match.")

    metadata = {"version": version, "commit": commit, "commitFull": commit_full}
    release_json = (json.dumps(metadata, indent=2) + "\n").encode()
    output_root = ROOT / "releases"
    output_root.mkdir(exist_ok=True)
    destination = output_root / version
    if destination.exists():
        raise SystemExit(f"Refusing to overwrite an existing release: {destination}")

    with tempfile.TemporaryDirectory(prefix="index-release-", dir=output_root) as temporary:
        staging = Path(temporary) / version
        staging.mkdir()
        package = staging / f"polar-bear-index-v{version}.zip"
        with zipfile.ZipFile(package, "w") as bundle:
            for name, data in (("index.html", html), ("release.json", release_json)):
                entry = zipfile.ZipInfo(name, zip_date)
                entry.create_system = 3
                entry.external_attr = 0o100644 << 16
                bundle.writestr(entry, data)
        with zipfile.ZipFile(package) as bundle:
            if bundle.testzip() is not None or bundle.read("index.html") != html:
                raise SystemExit("Release package verification failed.")
            if json.loads(bundle.read("release.json")) != metadata:
                raise SystemExit("Release metadata verification failed.")
        checksum = hashlib.sha256(package.read_bytes()).hexdigest()
        (staging / "SHA256SUMS.txt").write_text(f"{checksum}  {package.name}\n", encoding="utf-8")
        (staging / "release.json").write_bytes(release_json)
        (staging / "release-notes.md").write_text(
            f"北极熊单页 v{version}\n\n"
            "- 版权品牌根据访问主域名自动显示，支持子域名与标准公共后缀规则。\n"
            "- 浏览器首选语言为中文时显示中文版，其他语言显示英文版。\n"
            "- 右上角可手动切换中文与 English，并在浏览器允许时记住选择。\n"
            "- 保留北极熊插画、深色背景及备案外链；长名称或窄屏下页脚整体居中分行。\n"
            "- 版本、stable 标识和提交号来自本次发布，内置域名解析库无需外部请求。\n\n"
            f"源码提交：`{commit_full}`\n\n"
            "部署时将 ZIP 内的 index.html 和 release.json 放在同一目录；"
            "只拉取源码不会生成发布元数据。SHA256SUMS.txt 可用于校验下载包。\n"
            "此发布提供静态文件包，不代表远程服务器已部署。\n",
            encoding="utf-8",
        )
        staging.rename(destination)
    print(json.dumps({**metadata, "directory": str(destination)}, ensure_ascii=False))


if __name__ == "__main__":
    main()
