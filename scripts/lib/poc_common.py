# SPDX-License-Identifier: LGPL-2.1-or-later
"""Shared helpers for the project's Python scripts.

Works with the Python 3.9 that ships with the Xcode Command Line Tools, so a
fresh Mac needs no extra Python installation.
"""
import hashlib
import os
import re
import shutil
import subprocess
import tarfile
import urllib.request
from pathlib import Path

PROJECT = Path(__file__).resolve().parents[2]
CONFIGS = PROJECT / 'configs'


def _load_defaults():
    values = {}
    for line in (CONFIGS / 'build.env').read_text().splitlines():
        line = line.strip()
        if not line or line.startswith('#') or '=' not in line:
            continue
        key, value = line.split('=', 1)
        values[key] = os.environ.get(key, value)
    return values


SETTINGS = _load_defaults()
WORK = Path(os.environ.get('POC_WORK_DIR', PROJECT / 'work')).resolve()
POC_ROOT = WORK / 'poc'
STAGE = POC_ROOT / 'stage'
DEPS = STAGE / 'deps-x64'
CROSSOVER_PORT = WORK / 'crossover-port'
DEPLOYMENT_TARGET = SETTINGS['POC_MACOSX_DEPLOYMENT_TARGET']

# Suffix that identifies the private dependency directory regardless of where
# the repository lived when the binaries were linked.
DEPS_LIB_SUFFIX = '/poc/stage/deps-x64/lib'


def sha256_file(path):
    hasher = hashlib.sha256()
    with open(path, 'rb') as stream:
        for block in iter(lambda: stream.read(1 << 20), b''):
            hasher.update(block)
    return hasher.hexdigest()


def download_verified(url, destination, sha256):
    """Download to a temporary name, verify, then move into place."""
    destination = Path(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        if sha256_file(destination) != sha256:
            raise SystemExit(f'Hash mismatch: {destination}; delete it to download again')
        return destination
    partial = destination.with_name(destination.name + '.part')
    print('Downloading', url, flush=True)
    try:
        curl = shutil.which('curl') or '/usr/bin/curl'
        if Path(curl).exists():
            # curl uses the system trust store and honours proxy variables.
            subprocess.run([curl, '-fL', '--retry', '3', '-o', str(partial), url], check=True)
        else:
            urllib.request.urlretrieve(url, partial)
        if sha256_file(partial) != sha256:
            raise SystemExit(f'Hash mismatch after download: {url}')
        partial.replace(destination)
    finally:
        partial.unlink(missing_ok=True)
    return destination


def extract_tar(archive, destination, members=None):
    """Extract safely on old and new Python versions."""
    destination = Path(destination).resolve()
    with tarfile.open(archive) as tf:
        selected = tf.getmembers() if members is None else [
            m for m in tf.getmembers()
            if any(m.name == p or m.name.startswith(p.rstrip('/') + '/') for p in members)]
        if hasattr(tarfile, 'data_filter'):
            tf.extractall(destination, members=selected, filter='data')
            return
        for member in selected:
            target = (destination / member.name).resolve()
            if target != destination and destination not in target.parents:
                raise SystemExit(f'Unsafe path in {archive}: {member.name}')
            if member.issym() or member.islnk():
                link = Path(member.linkname)
                base = destination if member.islnk() else target.parent
                if link.is_absolute() or destination not in (base / link).resolve().parents:
                    raise SystemExit(f'Unsafe link in {archive}: {member.name}')
            if member.isdev():
                raise SystemExit(f'Device node in {archive}: {member.name}')
        tf.extractall(destination, members=selected)


# ---------------------------------------------------------------- Mach-O ----

MACHO_MAGICS = (b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca')
SYSTEM_PREFIXES = ('/usr/lib/', '/System/Library/')


def is_macho(path):
    path = Path(path)
    if not path.is_file() or path.is_symlink():
        return False
    with path.open('rb') as stream:
        return stream.read(4) in MACHO_MAGICS


def _output(*args):
    return subprocess.check_output(args, text=True)


def linked_libraries(path):
    return [line.strip().split(' (')[0] for line in _output('/usr/bin/otool', '-L', str(path)).splitlines()[1:]]


def install_id(path):
    lines = _output('/usr/bin/otool', '-D', str(path)).splitlines()[1:]
    return lines[0].strip() if lines else None


def load_commands(path):
    return _output('/usr/bin/otool', '-l', str(path))


def rpaths(path):
    return re.findall(r'cmd LC_RPATH\s+cmdsize \d+\s+path (.*?) \(offset', load_commands(path))


def minimum_macos(path):
    """Highest minimum macOS version across all slices, as a version tuple."""
    text = load_commands(path)
    found = re.findall(r'cmd LC_BUILD_VERSION\s+cmdsize \d+\s+platform 1\s+minos ([\d.]+)', text)
    found += re.findall(r'cmd LC_VERSION_MIN_MACOSX\s+cmdsize \d+\s+version ([\d.]+)', text)
    return max((version_tuple(v) for v in found), default=None)


def version_tuple(text):
    parts = tuple(int(part) for part in str(text).split('.'))
    return parts + (0,) * max(0, 3 - len(parts))


def version_text(version):
    return '.'.join(str(part) for part in version) if version else 'unknown'


def is_private_dependency(name, deps_lib=DEPS / 'lib'):
    """True for libraries from the project's dependency stage, from any checkout path."""
    return (name.startswith(str(deps_lib) + '/')
            or Path(name).parent.as_posix().endswith(DEPS_LIB_SUFFIX))


def relocate_macho(path, new_rpath, private_id=False, deps_lib=DEPS / 'lib'):
    """Point private dependencies at @rpath, replace build rpaths and re-sign.

    Returns the list of [old, new] dependency changes.
    """
    path = str(path)
    command = ['/usr/bin/install_name_tool']
    changes = []
    for dependency in linked_libraries(path):
        if is_private_dependency(dependency, deps_lib):
            replacement = '@rpath/' + Path(dependency).name
            command += ['-change', dependency, replacement]
            changes.append([dependency, replacement])
    current_id = install_id(path)
    if current_id and not current_id.startswith('@rpath/') and (
            private_id or is_private_dependency(current_id, deps_lib)):
        command += ['-id', '@rpath/' + Path(current_id).name]
    existing = rpaths(path)
    for old in existing:
        if old.rstrip('/') == str(deps_lib) or old.rstrip('/').endswith(DEPS_LIB_SUFFIX):
            command += ['-delete_rpath', old]
    if new_rpath not in existing:
        command += ['-add_rpath', new_rpath]
    if len(command) > 1:
        subprocess.run(command + [path], check=True, capture_output=True)
    subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', path], check=True, capture_output=True)
    return changes


def external_dependencies(path):
    """Absolute non-system dependencies and rpaths that will not exist on another Mac."""
    bad = [d for d in linked_libraries(path) if d.startswith('/') and not d.startswith(SYSTEM_PREFIXES)]
    bad += ['LC_RPATH ' + r for r in rpaths(path) if r.startswith('/') and not r.startswith(SYSTEM_PREFIXES)]
    return bad
