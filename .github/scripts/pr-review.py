#!/usr/bin/env python3
"""
Claude PR Review Script
Reviews GitHub PRs using Claude API with special handling for Dependabot
"""

import os
import re
import json
import sys
from anthropic import Anthropic
from github import Github, Auth

def get_pr_details():
    """Get PR details from GitHub API"""
    token = os.getenv('GITHUB_TOKEN')
    owner = os.getenv('REPO_OWNER')
    repo = os.getenv('REPO_NAME')
    pr_number = int(os.getenv('PR_NUMBER'))

    g = Github(auth=Auth.Token(token))
    repository = g.get_repo(f"{owner}/{repo}")
    pr = repository.get_pull(pr_number)

    return pr, g

def parse_semver(version_str):
    """Parse a version string like '2.0.28' into a tuple for comparison, None if unparseable"""
    v = version_str.lstrip('v')
    try:
        return tuple(int(x) for x in v.split('.'))
    except ValueError:
        return None

def get_upstream_release_notes(pr_title, g):
    """Try to fetch release notes from upstream GitHub repo for Dependabot PRs"""
    match = re.search(r'bump (\S+) from (\S+) to (\S+)', pr_title, re.IGNORECASE)
    if not match:
        return None

    package, old_version, new_version = match.groups()

    # Strip common registry prefixes to get owner/repo
    github_repo = re.sub(r'^(ghcr\.io|docker\.io|quay\.io)/', '', package)

    # Only try if it looks like owner/repo (exactly one slash)
    if github_repo.count('/') != 1:
        return None

    try:
        repo = g.get_repo(github_repo)
        releases = repo.get_releases()

        old_ver = parse_semver(old_version)
        new_ver = parse_semver(new_version)

        results = []
        for release in releases:
            tag_ver = parse_semver(release.tag_name)
            if tag_ver is None:
                continue  # skip alpha/rc/testing releases
            if tag_ver <= old_ver:
                break
            if tag_ver <= new_ver and release.body:
                results.append({
                    'tag': release.tag_name,
                    'url': release.html_url,
                    'body': release.body,
                })

        if results:
            print(f"Found {len(results)} upstream release(s) for {github_repo}")
            return results
        else:
            print(f"No upstream release notes found for {github_repo} ({old_version}->{new_version})")
            return None
    except Exception as e:
        print(f"Could not fetch upstream release notes for {github_repo}: {e}")
        return None

def get_pr_diff(pr, g):
    """Get the diff from a PR"""
    diff = pr.get_commits().reversed[0].commit.message if pr.get_commits().totalCount > 0 else ""

    # Get changed files
    files_info = []
    for file in pr.get_files():
        files_info.append({
            'filename': file.filename,
            'additions': file.additions,
            'deletions': file.deletions,
            'patch': file.patch or "No patch available",
            'status': file.status
        })

    is_dependabot = pr.user.login == 'dependabot[bot]'
    upstream_release_notes = None
    if is_dependabot:
        upstream_release_notes = get_upstream_release_notes(pr.title, g)

    return {
        'title': pr.title,
        'body': pr.body or "",
        'author': pr.user.login,
        'is_dependabot': is_dependabot,
        'files': files_info,
        'commits': pr.get_commits().totalCount,
        'upstream_release_notes': upstream_release_notes,
    }

def build_system_prompt():
    """Build the system prompt for concise reviews"""
    return (
        "You are a concise code reviewer. "
        "Use short bullet points. No filler, no praise, no pleasantries. "
        "Only mention issues or noteworthy changes. "
        "If everything looks fine, say so in one line."
    )

def build_review_prompt(pr_data):
    """Build the Claude prompt for code review"""
    is_dependabot = pr_data['is_dependabot']

    if is_dependabot:
        upstream_releases = pr_data.get('upstream_release_notes')
        if upstream_releases:
            combined = "\n\n".join(f"### {r['tag']}\n{r['body']}" for r in upstream_releases)
            release_notes_section = f"Upstream Release Notes:\n{combined[:3000]}"
        else:
            release_notes_section = f"Dependabot PR Body (no upstream release notes found):\n{pr_data['body'][:3000]}"

        prompt = f"""Dependabot PR:

Title: {pr_data['title']}

{release_notes_section}

Files:
"""
        for file in pr_data['files']:
            prompt += f"- {file['filename']} (+{file['additions']}/-{file['deletions']})\n"

        prompt += """
Reply with ONLY this format (no other text):

| | |
|---|---|
| **Type** | Minor/Patch/Major/Security |
| **Risk** | Low/Medium/High |
| **Change** | One sentence |
| **Security** | None / CVE/GHSA fixed: ... / Security-relevant because ... |
| **Action** | None / Manual testing needed because ... |

IMPORTANT: Carefully check the release notes for security advisories (GHSA, CVE), security fixes, or breaking changes. If present, reflect them in Type, Risk, Security, and Action."""
    else:
        prompt = f"""Review this PR. Be brief - bullet points only.

Title: {pr_data['title']}
Description: {pr_data['body']}
Author: {pr_data['author']}

Changes:
"""
        for file in pr_data['files']:
            prompt += f"\n### {file['filename']} ({file['status']})\n"
            if file['patch']:
                prompt += f"```diff\n{file['patch'][:2000]}\n```"

        prompt += """

Reply with:
- **Summary**: 1-2 sentences max
- **Security**: Flag any security issues (exposed secrets, injection, misconfigs, insecure defaults). ALWAYS include this section - either list issues or say "No issues".
- **Issues**: List only actual problems (bugs, correctness). Skip if none.
- **Suggestions**: Max 3 concrete improvements. Include code snippets only if helpful. Skip if none.

Do NOT list categories with "no issues found" - except Security, which must always be present."""

    return prompt

def review_with_claude(pr_data):
    """Send PR to Claude for review"""
    client = Anthropic()
    prompt = build_review_prompt(pr_data)
    max_tokens = 500 if pr_data['is_dependabot'] else 800

    message = client.messages.create(
        model="claude-sonnet-4-5-20250929",
        max_tokens=max_tokens,
        system=build_system_prompt(),
        messages=[
            {"role": "user", "content": prompt}
        ]
    )

    return message.content[0].text

def format_github_comment(review, pr_data):
    """Format review as GitHub comment"""
    is_dependabot = pr_data['is_dependabot']

    if is_dependabot:
        header = "Dependabot PR Summary (by Claude)"
    else:
        header = "Code Review (by Claude)"

    upstream_releases = pr_data.get('upstream_release_notes')
    if is_dependabot and upstream_releases:
        links = " | ".join(f"[{r['tag']}]({r['url']})" for r in upstream_releases)
        release_links = f"\n**Release Notes:** {links}\n"
    else:
        release_links = ""

    comment = f"""## {header}

{review}
{release_links}
---
*Review generated by Claude AI. Please use your judgment for final approval.*
"""

    return comment

def main():
    try:
        print("Fetching PR details...")
        pr, g = get_pr_details()

        print(f"Analyzing PR #{pr.number}: {pr.title}")
        pr_data = get_pr_diff(pr, g)

        print(f"Sending to Claude (Dependabot: {pr_data['is_dependabot']})...")
        review = review_with_claude(pr_data)

        print("Formatting comment...")
        comment = format_github_comment(review, pr_data)

        # Write to file for GitHub Action to pick up
        with open('/tmp/claude_review.md', 'w') as f:
            f.write(comment)

        print("Review complete!")
        print(comment)

    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)

if __name__ == '__main__':
    main()
