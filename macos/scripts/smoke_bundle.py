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
    for course in ('ELEC6008', 'ELEC6103'):
        for index in (1, 2):
            (downloads / f'{course} Lecture {index}.md').write_text(
                f'# {course} Lecture {index}\nMachine learning classification regression models and training data.'
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
    assert len(scanned['snapshot']['members']) == 4, scanned
    call(action='edit', plan_id=plan, command='rename', args=['ELEC6008', 'Demo Course'])
    topic_key = next(member['topic_key'] for member in scanned['snapshot']['members']
                     if member['topic'] == 'ELEC6008')
    moves = call(action='preview', plan_id=plan, topic_key=topic_key)['moves']
    assert len(moves) == 2
    applied = call(action='apply', plan_id=plan, confirmed=True, moves=moves)
    assert applied['snapshot']['plan_id'] == plan
    remaining_key = next(member['topic_key'] for member in applied['snapshot']['members']
                         if not member['applied'] and member['topic_key'])
    dismissed = call(action='edit', plan_id=plan, command='dismiss-topic', args=[remaining_key])
    assert any(member['excluded'] for member in dismissed['snapshot']['members'])
    call(action='edit', plan_id=plan, command='restore-topic', args=[remaining_key])
    assert all(Path(item['destination']).exists() for item in moves)
    batch = applied['snapshot']['history'][0]['id']
    call(action='undo', batch_id=batch, confirmed=True)
    assert len(list(downloads.glob('*.md'))) == 4
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    print('PASS: relocated bundle; network denied; per-topic apply/dismiss/restore/undo; signature preserved')
    print(scanned['message'])
