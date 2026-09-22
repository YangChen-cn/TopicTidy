#!/usr/bin/env python3
"""Build a relocatable Apple Silicon bundle, sign nested code, produce a ZIP."""
import argparse
import hashlib
import os
import pathlib
import plistlib
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request

URL = 'https://github.com/astral-sh/python-build-standalone/releases/download/20260901/cpython-3.12.14%2B20260901-aarch64-apple-darwin-install_only_stripped.tar.gz'
SHA256 = '81a359f1cfadd4da11766534c5913791cea55f26e1bb902cacd2a531bb1e4b2b'
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
# Installed command shebangs and pip metadata must not retain staging/source paths.
for path in (resources / 'python/bin').iterdir():
    if not path.name.startswith('python'):
        path.unlink()
for path in (resources / 'python').rglob('direct_url.json'):
    path.unlink()
for path in list((resources / 'python').rglob('__pycache__')):
    if path.exists(): shutil.rmtree(path)
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
                  'CFBundleShortVersionString': '0.7.0', 'CFBundleVersion': '1',
                  'CFBundleIconFile': 'AppIcon', 'LSMinimumSystemVersion': '15.0',
                  'LSUIElement': True, 'NSHighResolutionCapable': True,
                  'NSDownloadsFolderUsageDescription': '读取下载文件并按您确认的方案整理。'}, handle)
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
zip_path = dist / 'TopicTidy-0.7.0-arm64.zip'
subprocess.run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(output), str(zip_path)], check=True)
print(f'APP: {output}\nZIP: {zip_path}\nSHA256: {hashlib.sha256(zip_path.read_bytes()).hexdigest()}')
