#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
"""Publish a checked, complete Wine release to the public static manifest branch."""
import argparse
import base64
import hashlib
import json
import os
import plistlib
import re
import subprocess
import urllib.parse
import urllib.request


def gh(*args, payload=None, allow_missing=False):
    command = ['gh', *args]
    if payload is not None:
        command += ['--input', '-']
    result = subprocess.run(command, input=json.dumps(payload) if payload is not None else None,
                            text=True, capture_output=True)
    if result.returncode:
        if allow_missing and '(HTTP 404)' in result.stderr:
            return None
        raise RuntimeError(result.stderr.strip())
    return json.loads(result.stdout) if result.stdout.strip() else None


def version(info):
    value = tuple(info['version'][key] for key in ('major', 'minor', 'patch'))
    if any(type(n) is not int or n < 0 for n in value):
        raise ValueError('Invalid runtime version')
    return value


def download(url):
    request = urllib.request.Request(url, headers={'User-Agent': 'Wine-Runtime-Channel'})
    with urllib.request.urlopen(request, timeout=60) as response:
        data = response.read(65537)
    if len(data) > 65536:
        raise ValueError('Version manifest exceeds 64 KiB')
    return data


def manifest_for_release(repo, release):
    if release['draft']:
        raise ValueError('Release must be published')
    assets = {a['name']: a for a in release['assets'] if a['state'] == 'uploaded'}
    if not {'Libraries.tar.gz', 'WhiskyWineVersion.plist'} <= assets.keys():
        return None
    archive = assets['Libraries.tar.gz']
    metadata = assets['WhiskyWineVersion.plist']
    tag = urllib.parse.quote(release['tag_name'], safe='')
    prefix = f'https://github.com/{repo}/releases/download/{tag}/'
    if archive['browser_download_url'] != prefix + 'Libraries.tar.gz':
        raise ValueError('Unexpected archive download URL')
    if metadata['browser_download_url'] != prefix + 'WhiskyWineVersion.plist':
        raise ValueError('Unexpected metadata download URL')
    raw = download(metadata['browser_download_url'])
    info = plistlib.loads(raw)
    version(info)
    digest = info.get('sha256', '')
    if not re.fullmatch('[0-9a-f]{64}', digest):
        raise ValueError('A valid archive SHA-256 is required')
    asset_digest = archive.get('digest')
    if asset_digest:
        if asset_digest != 'sha256:' + digest:
            raise ValueError('Archive asset digest disagrees with version metadata')
    else:
        hasher = hashlib.sha256()
        with urllib.request.urlopen(archive['browser_download_url'], timeout=120) as response:
            for block in iter(lambda: response.read(1 << 20), b''):
                hasher.update(block)
        if hasher.hexdigest() != digest:
            raise ValueError('Downloaded archive digest disagrees with version metadata')
    # Only public runtime fields enter the channel; publisher metadata stays local.
    public = {key: info[key] for key in ('version', 'sha256', 'dxvkVersion', 'dxmtVersion', 'gptkCapable') if key in info}
    public['downloadURL'] = archive['browser_download_url']
    encoded = plistlib.dumps(public)
    if re.search(rb'/(?:Users|home)/[A-Za-z0-9_.-]+/|-----BEGIN .*PRIVATE KEY-----|github_pat_|ghp_', encoded):
        raise ValueError('Private data pattern in manifest')
    return public


def publish(repo, info):
    ref = gh('api', f'repos/{repo}/git/ref/heads/runtime-channel', allow_missing=True)
    previous = gh('api', f'repos/{repo}/contents/WhiskyWineVersion.plist?ref=runtime-channel', allow_missing=True) if ref else None
    if previous:
        old = plistlib.loads(base64.b64decode(previous['content']))
        if version(info) < version(old):
            print('Keeping the newer runtime already in the channel')
            return
        if version(info) == version(old) and info.get('sha256') != old.get('sha256'):
            raise ValueError('A changed runtime archive requires an increased version')
        if info == old:
            print('Runtime channel already current')
            return
    blob = gh('api', '--method', 'POST', f'repos/{repo}/git/blobs', payload={
        'content': base64.b64encode(plistlib.dumps(info)).decode(), 'encoding': 'base64'})
    tree = gh('api', '--method', 'POST', f'repos/{repo}/git/trees', payload={
        'tree': [{'path': 'WhiskyWineVersion.plist', 'mode': '100644', 'type': 'blob', 'sha': blob['sha']}]})
    parents = [ref['object']['sha']] if ref else []
    commit = gh('api', '--method', 'POST', f'repos/{repo}/git/commits', payload={
        'message': 'Publish Wine runtime ' + '.'.join(map(str, version(info))),
        'tree': tree['sha'], 'parents': parents,
        'author': {'name': 'Wine Runtime CI', 'email': 'runtime-channel@users.noreply.github.com'}})
    if ref:
        gh('api', '--method', 'PATCH', f'repos/{repo}/git/refs/heads/runtime-channel', payload={'sha': commit['sha'], 'force': False})
    else:
        gh('api', '--method', 'POST', f'repos/{repo}/git/refs', payload={'ref': 'refs/heads/runtime-channel', 'sha': commit['sha']})
    print(f'Published https://raw.githubusercontent.com/{repo}/runtime-channel/WhiskyWineVersion.plist')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', default=os.environ.get('GH_REPO') or os.environ.get('GITHUB_REPOSITORY'))
    parser.add_argument('--tag', default='', help='Specific release tag; default selects the newest compatible release')
    parser.add_argument('--check-only', action='store_true')
    args = parser.parse_args()
    if not args.repo or not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', args.repo):
        parser.error('Provide owner/repository')
    if args.tag:
        release = gh('api', f'repos/{args.repo}/releases/tags/{urllib.parse.quote(args.tag, safe="")}')
        releases = [release]
    else:
        releases = gh('api', f'repos/{args.repo}/releases?per_page=100')
        releases = sorted((r for r in releases if not r['draft'] and r['published_at']),
                          key=lambda r: r['published_at'], reverse=True)
    for release in releases:
        info = manifest_for_release(args.repo, release)
        if info:
            if args.check_only:
                print(json.dumps(info, indent=2))
            else:
                publish(args.repo, info)
            return
    print('Waiting for a release carrying Libraries.tar.gz and WhiskyWineVersion.plist')


if __name__ == '__main__':
    main()
