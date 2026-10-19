#!/usr/bin/env python3
"""Build a dependency-free bilingual Pages site with project-path-safe links."""
import argparse
import json
from html import escape
from html.parser import HTMLParser
from pathlib import Path
import re
import shutil
from string import Template
from urllib.parse import urlsplit


EN = dict(
    lang="en", title="WeGit — A native Git workbench for macOS",
    description="Read diffs, prepare commits, explore history and sync your repositories in a native macOS Git workbench. Open source under MIT.",
    skip="Skip to content", navigation="Main navigation", features="Features", get="Get WeGit",
    other_lang="zh-Hans", other_label="简体中文", icon_alt="WeGit application icon",
    headline="Your changes, clearly.",
    intro="A native Git workbench for macOS. Read the diff, shape your next commit, and keep your repositories in view.",
    source="Explore on GitHub", requirements="macOS 27+ · Apple silicon · Git 2.46+",
    screenshot_alt="WeGit development build showing a split diff, changed files and the repository Inspector in English.",
    screenshot_caption="Actual development build with a test repository. The interface supports English, Chinese and custom themes.",
    workflow_title="From the first change to the next commit.",
    read_title="Read the whole change", read_body="Unified or split diffs, syntax highlighting and expandable context. Large changes load in pages; copied code keeps its original text.",
    commit_title="Prepare with care", commit_body="Stage files or individual hunks, keep a commit draft, and review what is ready. Explore history and branch from any commit.",
    sync_title="Keep the target clear", sync_body="Choose the remote, branch and Pull strategy. Continue supported conflicts, and check an uncertain push before trying again.",
    personal="Light, Dark, or a complete palette of your own. Native keyboard shortcuts and a menu bar panel keep everyday work close.",
    preview="WeGit 1.0.0", get_title="Try WeGit on your Mac.",
    release_loading="Check GitHub Releases for published builds and installation notes.",
    release_link="View GitHub Releases", checksum="SHA-256", manifest="Source manifest",
    install_note="Current direct-distribution builds use ad-hoc signing and are not notarized. macOS may block the first launch. Read the release notes before installing.",
    apple_help="Apple’s opening guidance", readiness="Release notes and known limits", no_script="JavaScript is optional. Use GitHub Releases for published versions, checksums and installation notes.",
    build_title="Or build from source", build_body="Use Xcode 27 on an Apple silicon Mac running macOS 27. Local ad-hoc builds do not require an Apple developer account.",
    build_note="The app uses your Git installation. No hosting-provider account is required for local work.", commands_label="Build commands; scroll horizontally to read long lines",
    contribute_title="Help improve WeGit.", contribute_body="WeGit 1.0.0 is available with known validation limits, including deferred accessibility acceptance. Report a reproducible issue, suggest a workflow, or contribute through a linked pull request.",
    issue="Open an issue", footer="Native to macOS. Open source by WeOpen.", contributing="Contributing",
)
ZH = dict(
    lang="zh-Hans", title="WeGit — 原生 macOS Git 工作台",
    description="在原生 macOS Git 工作台中阅读差异、整理提交、查看历史与同步仓库。采用 MIT 开源许可。",
    skip="跳到正文", navigation="主导航", features="功能", get="获取 WeGit",
    other_lang="en", other_label="English", icon_alt="WeGit 应用图标", headline="每一次改动，清晰可见。",
    intro="为 macOS 打造的原生 Git 工作台。读懂差异，整理下一次提交，让仓库状态尽在眼前。",
    source="在 GitHub 探索", requirements="macOS 27 及以上 · Apple 芯片 · Git 2.46 及以上",
    screenshot_alt="WeGit 开发版本的英文界面，展示分栏差异、改动文件和仓库检查器。",
    screenshot_caption="开发版本真实界面，使用测试仓库。支持中英文和独立自定义配色。",
    workflow_title="从第一处改动，到下一次提交。",
    read_title="读懂完整差异", read_body="统一或分栏阅读，语法高亮与上下文展开。大差异按页加载，复制代码时保留原文。",
    commit_title="从容整理提交", commit_body="暂存文件或单个差异块，保留提交草稿，核对准备提交的内容。浏览历史，从任一提交建立分支。",
    sync_title="明确每次同步", sync_body="选择远端、目标分支和拉取策略。继续支持的冲突操作，推送结果不确定时先核对再重试。",
    personal="浅色、深色，或一套完整的自定义配色。原生键盘快捷键与菜单栏面板，让日常操作触手可及。",
    preview="WeGit 1.0.0", get_title="在你的 Mac 上体验 WeGit。",
    release_loading="公开版本及安装说明以 GitHub Releases 为准。",
    release_link="查看 GitHub Releases", checksum="SHA-256 校验和", manifest="来源清单",
    install_note="当前直接分发采用 ad-hoc 签名，未经 Apple 公证，macOS 可能阻止首次启动。安装前请阅读版本说明。",
    apple_help="Apple 的打开说明", readiness="版本说明与已知限制", no_script="无需 JavaScript 也可使用本页。请通过 GitHub Releases 查看公开版本、校验和与安装说明。",
    build_title="也可以从源码构建", build_body="在运行 macOS 27 的 Apple 芯片 Mac 上使用 Xcode 27。本地 ad-hoc 构建无需 Apple 开发者账号。",
    build_note="应用调用本机 Git。本地仓库操作不需要托管平台账号。", commands_label="构建命令；可水平滚动阅读长行",
    contribute_title="一起完善 WeGit。", contribute_body="WeGit 1.0.0 已提供下载，辅助功能暂缓验收，其他验证限制见版本说明。欢迎反馈可复现的问题、提出工作流需求，或通过关联 Issue 的 PR 参与开发。",
    issue="提交 Issue", footer="原生 macOS 体验，WeOpen 开源项目。", contributing="参与贡献",
)


class Links(HTMLParser):
    def __init__(self):
        super().__init__()
        self.targets = []
        self.ids = set()

    def handle_starttag(self, tag, attrs):
        values = dict(attrs)
        if values.get("id"):
            self.ids.add(values["id"])
        self.targets.extend(values[name] for name in ("href", "src", "srcset") if values.get(name))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=Path(".build/website"))
    parser.add_argument("--base-path", default="/WeGit")
    parser.add_argument("--releases-json", type=Path, help="Public GitHub release metadata fetched at deployment time")
    args = parser.parse_args()
    base = args.base_path.rstrip("/")
    if base and not re.fullmatch(r"(?:/[A-Za-z0-9_-]+)+", base):
        raise SystemExit("Base path must contain only project path segments.")
    if EN.keys() != ZH.keys():
        raise SystemExit("Website translations have different fields.")
    root = Path(__file__).resolve().parents[1]
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    releases = json.loads(args.releases_json.read_text()) if args.releases_json else []
    if not isinstance(releases, list):
        raise SystemExit("Release metadata must be a JSON array.")
    snapshot = [{"tag_name": item.get("tag_name"), "draft": item.get("draft"),
                 "prerelease": item.get("prerelease"), "assets": [
                     {"name": asset.get("name"), "browser_download_url": asset.get("browser_download_url")}
                     for asset in item.get("assets", [])]} for item in releases if item.get("draft") is False]
    (output / "releases.json").write_text(json.dumps(snapshot, ensure_ascii=False) + "\n")
    for name in ("style.css", "site.js", "release.mjs"):
        shutil.copy2(root / "site" / name, output / name)
    shutil.copytree(root / "site/assets", output / "assets", dirs_exist_ok=True)
    template = Template((root / "site/template.html").read_text())
    pages = ((EN, output / "index.html", base + "/zh/"), (ZH, output / "zh/index.html", base + "/"))
    for language, path, other in pages:
        values = {key: escape(value, quote=True) for key, value in language.items()}
        values.update(base=base, home=base + ("/zh/" if language is ZH else "/"), other_url=other)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(template.substitute(values))
    for _, path, _ in pages:
        links = Links()
        links.feed(path.read_text())
        for target in links.targets:
            url = urlsplit(target)
            if url.scheme:
                if url.scheme != "https":
                    raise SystemExit("Website links must use HTTPS: " + target)
                continue
            if url.fragment and not url.path:
                if url.fragment not in links.ids:
                    raise SystemExit("Missing fragment target: " + target)
                continue
            relative = url.path.removeprefix(base).lstrip("/")
            local = output / relative
            if not (local.is_file() or (local / "index.html").is_file()):
                raise SystemExit("Missing website asset or page: " + target)
    (output / ".nojekyll").write_text("")
    print("Website built: English/Chinese, project path, local links and assets verified at", output)


if __name__ == "__main__":
    main()
