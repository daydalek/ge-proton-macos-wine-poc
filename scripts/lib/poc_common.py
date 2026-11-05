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


def crossover_patch_series(project=PROJECT):
    """Ordered, project-relative CrossOver patches from configs/crossover-patch-series.txt."""
    lines = (project / 'configs/crossover-patch-series.txt').read_text().splitlines()
    series = tuple(line.strip() for line in lines if line.strip() and not line.lstrip().startswith('#'))
    if not series:
        raise ValueError('Empty CrossOver patch series')
    return series


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


# DXVK ships as a digest-pinned payload; never take it from a mutable tree.
# A DXVK build linked through winebuild carries the "Wine builtin DLL" DOS-stub
# signature, which makes Wine treat it as a builtin and silently skip it, so the
# only symptom is that 64-bit games fall back to wined3d.
DXVK_BASE_URL = 'https://github.com/daydalek/ge-proton-macos-wine-poc/releases/download/v0.1.0/Libraries.tar.gz'
DXVK_BASE_SHA256 = 'bb5f2f3d49e528e9200c02beb5b1e004c06ad00969a790285faa9ed46f900c60'
DXVK_VERSION = '1.10.3'


def resolve_pinned_dxvk(work=WORK, archive=None):
    """Extract ``Libraries/DXVK`` from the pinned archive and return its path."""
    work = Path(work)
    archive = Path(archive) if archive else work / 'whisky-dxvk-bootstrap.tar.gz'
    if not archive.exists():
        work.mkdir(parents=True, exist_ok=True)
        download_verified(DXVK_BASE_URL, archive, DXVK_BASE_SHA256)
    elif sha256_file(archive) != DXVK_BASE_SHA256:
        raise ValueError(f'DXVK bootstrap archive digest mismatch: {archive}')
    destination = work / 'dxvk-pinned'
    if destination.exists():
        shutil.rmtree(destination)
    destination.mkdir(parents=True)
    with tarfile.open(archive) as tf:
        for member in tf:
            if not member.name.startswith('Libraries/DXVK/') or not member.isfile():
                continue
            if Path(member.name).is_absolute() or '..' in Path(member.name).parts:
                raise ValueError('unexpected DXVK archive path')
            target = destination / member.name
            if destination.resolve() not in target.resolve().parents:
                raise ValueError('unexpected DXVK archive path')
            target.parent.mkdir(parents=True, exist_ok=True)
            with tf.extractfile(member) as source, target.open('wb') as output:
                shutil.copyfileobj(source, output)
    dxvk = destination / 'Libraries' / 'DXVK'
    for arch in ('x64', 'x32'):
        for name in ('d3d11.dll', 'd3d10core.dll'):
            if not (dxvk / arch / name).is_file():
                raise ValueError(f'incomplete DXVK payload: {dxvk / arch / name}')
    return dxvk


# The d3d11 video-device shim repairs Unity-style Media Foundation playback on
# DXVK (no VK_KHR_external_memory_win32): woven into the shipped DXVK payload it
# reaches every bottle, because Whisky's enableDXVK copies all payload DLLs into
# the prefix on each DXVK-enabled launch.
D3D11_SHIM_MARKER = b'd3d11_original'
D3D11_SHIM_ARCHES = ('x64', 'x32')


def build_d3d11_video_shim(work=WORK, poc=PROJECT):
    """Build the d3d11 video shim for both architectures; returns the output dir."""
    out = Path(work) / 'd3d11-video-shim'
    subprocess.run(['bash', str(Path(poc) / 'native/d3d11-video-shim/build.sh'), str(out)],
                   check=True, cwd=poc)
    return out


def weave_d3d11_video_shim(dxvk_dir, shim_root):
    """Install the shim as each arch's ``d3d11.dll``, wrapping the payload's own
    DLL renamed to ``d3d11_original.dll``. Idempotent: refreshes the shim on an
    already-woven payload. Returns the list of woven arch directories."""
    dxvk_dir = Path(dxvk_dir)
    woven = []
    for arch in D3D11_SHIM_ARCHES:
        target = dxvk_dir / arch / 'd3d11.dll'
        original = dxvk_dir / arch / 'd3d11_original.dll'
        shim = Path(shim_root) / arch / 'd3d11.dll'
        if not target.is_file():
            continue
        if not shim.is_file():
            raise ValueError(f'missing shim binary: {shim} (run native/d3d11-video-shim/build.sh)')
        if D3D11_SHIM_MARKER not in shim.read_bytes():
            raise ValueError(f'{shim} is not a d3d11 video shim')
        if D3D11_SHIM_MARKER in target.read_bytes():
            if not original.is_file():
                raise ValueError(f'{target} is already a shim but {original} is missing')
        elif not original.is_file():
            target.rename(original)
        shutil.copy2(shim, target)
        woven.append(arch)
    return woven
