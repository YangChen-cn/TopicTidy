#!/usr/bin/env python3
"""Build a relocatable Apple Silicon bundle, sign nested code, produce a DMG."""
import argparse
import atexit
import hashlib
import json
import os
import pathlib
import plistlib
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request

from prune_runtime import CLI_ONLY_PACKAGES, prune

URL = 'https://github.com/astral-sh/python-build-standalone/releases/download/20260901/cpython-3.12.14%2B20260901-aarch64-apple-darwin-install_only_stripped.tar.gz'
SHA256 = '81a359f1cfadd4da11766534c5913791cea55f26e1bb902cacd2a531bb1e4b2b'
VERSION = '0.9.0'
parser = argparse.ArgumentParser()
parser.add_argument('--identity', default='TopicTidy')
parser.add_argument('--runtime', type=pathlib.Path)
args = parser.parse_args()
root = pathlib.Path(__file__).resolve().parents[2]
package = root / 'macos'
env = dict(os.environ, MACOSX_DEPLOYMENT_TARGET='15.0')
subprocess.run(['swift', 'build', '-c', 'release', '--package-path', str(package),
                '-Xswiftc', '-debug-prefix-map', '-Xswiftc', f'{root}=.'], check=True, env=env)
bin_dir = subprocess.check_output(['swift', 'build', '-c', 'release', '--package-path', str(package), '--show-bin-path'], text=True).strip()
staging = pathlib.Path(tempfile.mkdtemp(prefix='topictidy-bundle-'))
atexit.register(shutil.rmtree, staging, ignore_errors=True)
app = staging / 'TopicTidy.app'
contents = app / 'Contents'
resources = contents / 'Resources'
(contents / 'MacOS').mkdir(parents=True)
resources.mkdir()
shutil.copy2(pathlib.Path(bin_dir) / 'TopicTidy', contents / 'MacOS' / 'TopicTidy')
subprocess.run(['strip', '-S', str(contents / 'MacOS' / 'TopicTidy')], check=True)
archive = args.runtime or staging / 'python.tar.gz'
if not args.runtime:
    urllib.request.urlretrieve(URL, archive)
if hashlib.sha256(archive.read_bytes()).hexdigest() != SHA256:
    raise RuntimeError('Python archive checksum mismatch')
with tarfile.open(archive) as tar:
    tar.extractall(resources, filter='data')
python = resources / 'python/bin/python3'
subprocess.run([str(python), '-m', 'pip', 'install', '--no-compile', '-c', str(package / 'runtime-constraints.txt'), str(root)], check=True)
helpers = resources / 'helpers'
helpers.mkdir()
for name, framework in [('embedding', 'NaturalLanguage'), ('translation', 'Translation')]:
    command = ['xcrun', 'swiftc', '-O', '-target', 'arm64-apple-macosx15.0',
               '-debug-prefix-map', f'{root}=.',
               str(root / f'src/downloads_organizer/native/{name}.swift'),
               '-framework', framework, '-o', str(helpers / f'native-{name}')]
    if name == 'translation': command.insert(2, '-parse-as-library')
    subprocess.run(command, check=True)
iconset = staging / 'AppIcon.iconset'
iconset.mkdir()
for size in (16, 32, 128, 256, 512):
    for scale in (1, 2):
        suffix = '@2x' if scale == 2 else ''
        subprocess.run(['sips', '-z', str(size*scale), str(size*scale),
                        str(package / 'Assets/AppIcon.png'), '--out',
                        str(iconset / f'icon_{size}x{size}{suffix}.png')], check=True, stdout=subprocess.DEVNULL)
subprocess.run(['iconutil', '-c', 'icns', str(iconset), '-o', str(resources / 'AppIcon.icns')], check=True)
with (contents / 'Info.plist').open('wb') as handle:
    plistlib.dump({'CFBundleIdentifier': 'com.topictidy.app', 'CFBundleName': 'TopicTidy',
                  'CFBundleExecutable': 'TopicTidy', 'CFBundlePackageType': 'APPL',
                  'CFBundleShortVersionString': VERSION, 'CFBundleVersion': '1',
                  'CFBundleIconFile': 'AppIcon', 'LSMinimumSystemVersion': '15.0',
                  'LSUIElement': True, 'NSHighResolutionCapable': True,
                  'NSDownloadsFolderUsageDescription': '读取下载文件并按您确认的方案整理。'}, handle)

def allocated_kib(path: pathlib.Path) -> int:
    return int(subprocess.check_output(['du', '-sk', str(path)], text=True).split()[0])


# Measure the same core-only bundle before conservative runtime pruning.
unpruned_app_kib = allocated_kib(app)
unpruned_dmg_root = staging / 'unpruned-dmg-root'
unpruned_dmg_root.mkdir()
shutil.copytree(app, unpruned_dmg_root / 'TopicTidy.app', symlinks=True)
unpruned_dmg = staging / 'TopicTidy-unpruned.dmg'
subprocess.run([
    'hdiutil', 'create', '-volname', 'TopicTidy Unpruned', '-srcfolder', str(unpruned_dmg_root),
    '-ov', '-format', 'UDZO', str(unpruned_dmg),
], check=True, stdout=subprocess.DEVNULL)
unpruned_dmg_bytes = unpruned_dmg.stat().st_size

prune_result = prune(resources / 'python')
site_packages = resources / 'python/lib/python3.12/site-packages'
for forbidden in (*CLI_ONLY_PACKAGES, 'pip', 'setuptools'):
    if any(site_packages.glob(f'{forbidden}*')):
        raise RuntimeError(f'GUI runtime still contains excluded package: {forbidden}')
# Reject any developer/source path in distributable bytes before signing.
for path in app.rglob('*'):
    if path.is_file() and not path.is_symlink():
        data = path.read_bytes()
        if any(needle in data for needle in (str(root).encode(), str(staging).encode(), b'/Users/yang/')):
            raise RuntimeError(f'Build path leaked into {path.relative_to(app)}')
mach_magics = {b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca'}
for path in sorted(app.rglob('*'), key=lambda p: len(p.parts), reverse=True):
    if path.is_file() and not path.is_symlink():
        with path.open('rb') as file: magic = file.read(4)
        if magic in mach_magics:
            subprocess.run(['codesign', '--force', '--sign', args.identity, '--timestamp=none', str(path)], check=True)
subprocess.run(['codesign', '--force', '--sign', args.identity, '--timestamp=none', str(app)], check=True)
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
dist = root / 'dist'
dist.mkdir(exist_ok=True)
output = dist / 'TopicTidy.app'
if output.exists(): shutil.rmtree(output)
shutil.copytree(app, output, symlinks=True)
dmg_root = staging / 'dmg-root'
dmg_root.mkdir()
shutil.copytree(app, dmg_root / 'TopicTidy.app', symlinks=True)
(dmg_root / 'Applications').symlink_to('/Applications')
dmg_path = dist / f'TopicTidy-{VERSION}-arm64.dmg'
if dmg_path.exists():
    dmg_path.unlink()
subprocess.run([
    'hdiutil', 'create', '-volname', 'TopicTidy', '-srcfolder', str(dmg_root),
    '-ov', '-format', 'UDZO', str(dmg_path),
], check=True, stdout=subprocess.DEVNULL)
subprocess.run(['codesign', '--force', '--sign', args.identity, '--timestamp=none', str(dmg_path)], check=True)
subprocess.run(['codesign', '--verify', '--strict', str(dmg_path)], check=True)
subprocess.run(['hdiutil', 'verify', str(dmg_path)], check=True, stdout=subprocess.DEVNULL)
report = {
    'version': VERSION,
    'app_unpruned_bytes': unpruned_app_kib * 1024,
    'app_pruned_bytes': allocated_kib(output) * 1024,
    'dmg_unpruned_bytes': unpruned_dmg_bytes,
    'dmg_pruned_bytes': dmg_path.stat().st_size,
    'runtime_unpruned_bytes': prune_result['before_bytes'],
    'runtime_pruned_bytes': prune_result['after_bytes'],
}
report_path = dist / f'TopicTidy-{VERSION}-size-report.json'
report_path.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
print(
    f'APP: {output}\nDMG: {dmg_path}\nSIZE REPORT: {report_path}\n'
    f'SHA256: {hashlib.sha256(dmg_path.read_bytes()).hexdigest()}'
)
shutil.rmtree(staging)
