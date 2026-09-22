#!/usr/bin/env python3
"""Relocate a distribution and exercise offline services using only temporary files."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

source = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix='topictidy-relocation-') as directory:
    root = Path(directory)
    app = root / 'Folder with spaces' / 'TopicTidy.app'
    shutil.copytree(source, app, symlinks=True)
    resources = app / 'Contents/Resources'
    downloads = root / 'Downloads'
    downloads.mkdir()
    for index in (1, 2):
        (downloads / f'ELEC6008 Lecture {index}.md').write_text(
            f'# ELEC6008 Lecture {index}\nMachine learning classification regression models and training data.'
        )
    env = {
        'PATH': '/usr/bin:/bin', 'HOME': os.environ['HOME'],
        'DOWNLOADS_ORGANIZER_DOWNLOADS': str(downloads),
        'DOWNLOADS_ORGANIZER_HOME': str(root / 'state'),
        'TOPICTIDY_HELPERS': str(resources / 'helpers'),
    }
    command = ['/usr/bin/sandbox-exec', '-p', '(version 1)(allow default)(deny network*)',
               str(resources / 'python/bin/python3'), '-I', '-B', '-m', 'downloads_organizer.gui_bridge']

    def call(**request):
        result = subprocess.run(command, input=json.dumps(request), text=True, capture_output=True,
                                cwd=root, env=env, check=True, timeout=180)
        response = json.loads(result.stdout)
        assert response['ok'], response
        return response

    assert call(action='status')['snapshot']['plan_id'] is None
    scanned = call(action='scan')
    plan = scanned['snapshot']['plan_id']
    assert len(scanned['snapshot']['members']) == 2, scanned
    call(action='edit', plan_id=plan, command='rename', args=['ELEC6008', 'Demo Course'])
    moves = call(action='preview', plan_id=plan)['moves']
    assert len(moves) == 2
    applied = call(action='apply', plan_id=plan, confirmed=True, moves=moves)
    assert all(Path(item['destination']).exists() for item in moves)
    batch = applied['snapshot']['history'][0]['id']
    call(action='undo', batch_id=batch, confirmed=True)
    assert len(list(downloads.glob('*.md'))) == 2
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    print('PASS: relocated bundle; network denied; scan/edit/preview/apply/undo; signature preserved')
    print(scanned['message'])
