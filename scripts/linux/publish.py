#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
"""Publish immutable Linux prereleases after verifying the downloaded CI artifacts."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

REQUIRED = {'wine-linux-amd64.tar.gz', 'wine-linux-amd64-sources.tar.gz',
            'linux-release-manifest.json', 'linux-static-check.json',
            'linux-privacy-audit.json', 'linux-ffmpeg-capabilities.json'}


def sha256(path):
    result = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(chunk)
    return result.hexdigest()


def verify(directory, commit):
    checksums = directory / 'SHA256SUMS-linux-amd64'
    records = {}
    for line in checksums.read_text().splitlines():
        digest, name = line.split('  ', 1)
        if not re.fullmatch(r'[0-9a-f]{64}', digest) or name != Path(name).name or name in records:
            raise ValueError('Invalid checksum entry')
        path = directory / name
        if path.is_symlink() or not path.is_file() or sha256(path) != digest:
            raise ValueError('Artifact checksum mismatch: ' + name)
        records[name] = digest
    if not REQUIRED <= records.keys():
        raise ValueError('Required Linux assets are missing')
    manifest = json.loads((directory / 'linux-release-manifest.json').read_text())
    if manifest['recipe_revision'] != commit or manifest['validation_mode'] not in ('runtime', 'compile-only'):
        raise ValueError('Artifacts require an exact recipe revision and explicit validation mode')
    for name in ('linux-static-check.json', 'linux-privacy-audit.json'):
        if json.loads((directory / name).read_text())['result'] != 'passed':
            raise ValueError('Static validation failed: ' + name)
    records[checksums.name] = sha256(checksums)
    return records, manifest


def gh(*args, payload=None, missing=False):
    command = ['gh', *args]
    if payload is not None:
        command += ['--input', '-']
    result = subprocess.run(command, input=json.dumps(payload) if payload is not None else None,
                            text=True, capture_output=True)
    if result.returncode:
        if missing and '(HTTP 404)' in result.stderr:
            return None
        raise RuntimeError(result.stderr.strip())
    return result.stdout


def api(path, **kwargs):
    raw = gh('api', path, **kwargs)
    return json.loads(raw) if raw else None


def verify_uploaded(release, records):
    assets = {a['name']: a for a in release['assets'] if a['state'] == 'uploaded'}
    for name, digest in records.items():
        if name not in assets or assets[name].get('digest') != 'sha256:' + digest:
            raise ValueError('Uploaded asset digest differs: ' + name)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', type=Path, required=True)
    parser.add_argument('--tag', required=True)
    parser.add_argument('--commit', required=True)
    parser.add_argument('--repo', default=os.environ.get('GH_REPO'))
    args = parser.parse_args()
    if not args.repo or not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', args.repo):
        parser.error('Provide owner/repository')
    if not re.fullmatch(r'v[0-9]+\.[0-9]+\.[0-9]+-linux-amd64', args.tag):
        parser.error('Use vMAJOR.MINOR.PATCH-linux-amd64')
    if not re.fullmatch('[0-9a-f]{40}', args.commit):
        parser.error('Provide the full recipe commit SHA')
    directory = args.directory.resolve()
    records, manifest = verify(directory, args.commit)
    base = 'repos/' + args.repo
    ref = api(base + '/git/ref/tags/' + args.tag, missing=True)
    if ref:
        obj = ref['object']
        while obj['type'] == 'tag':
            obj = api(base + '/git/tags/' + obj['sha'])['object']
        if obj['type'] != 'commit' or obj['sha'] != args.commit:
            raise ValueError('Existing release tag points to another revision')
    else:
        gh('api', '--method', 'POST', base + '/git/refs', payload={
            'ref': 'refs/tags/' + args.tag, 'sha': args.commit})
    release = api(base + '/releases/tags/' + args.tag, missing=True)
    if release and not release['draft']:
        verify_uploaded(release, records)
        print(release['html_url'])
        return
    mode = manifest['validation_mode']
    notes = ('Ubuntu 24.04 amd64; x86/x64 Windows modules through new WoW64.\n\n'
             'Includes the shared OP synchronization repair, seek-generation handling, '
             'and Linux Quartz no-position transition repair.\n\n'
             'Recipe commit: ' + args.commit + '\n\n'
             + ('Validation: compilation, PE/ELF, dependencies, FFmpeg capability inventory, '
                'privacy checks and checksums. Runtime/media probes are deferred for this build.\n'
                if mode == 'compile-only' else
                'Validation: build, static checks and the workflow runtime probe stages. '
                'Hardware GPU, desktop and real-game acceptance remain separate.\n'))
    files = [str(directory / name) for name in sorted(records)]
    if release:
        gh('release', 'upload', args.tag, '--repo', args.repo, '--clobber', *files)
    else:
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'notes.md'
            path.write_text(notes)
            gh('release', 'create', args.tag, '--repo', args.repo, '--verify-tag',
               '--draft', '--prerelease', '--title', args.tag + ' — Linux amd64',
               '--notes-file', str(path), *files)
    release = api(base + '/releases/tags/' + args.tag)
    verify_uploaded(release, records)
    gh('release', 'edit', args.tag, '--repo', args.repo, '--draft=false', '--prerelease')
    print(release['html_url'])


if __name__ == '__main__':
    main()
