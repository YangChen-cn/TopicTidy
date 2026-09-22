from pathlib import Path

import pytest

from downloads_organizer.gui_bridge import dispatch


@pytest.fixture
def gui(tmp_path, monkeypatch):
    downloads = tmp_path / 'Downloads'
    downloads.mkdir()
    monkeypatch.setenv('DOWNLOADS_ORGANIZER_DOWNLOADS', str(downloads))
    monkeypatch.setenv('DOWNLOADS_ORGANIZER_HOME', str(tmp_path / 'state'))
    for index in (1, 2):
        (downloads / f'ELEC6008 Lecture {index}.md').write_text(f'Chapter {index}')
    return downloads


def test_gui_preview_confirmation_apply_and_undo(gui):
    dispatch({'action': 'scan', 'semantic': False})  # Superseded draft must not reappear after apply.
    proposal = dispatch({'action': 'scan', 'semantic': False})
    plan = proposal['snapshot']['plan_id']
    assert len(proposal['snapshot']['members']) == 2
    with pytest.raises(ValueError, match='确认'):
        dispatch({'action': 'apply', 'plan_id': plan})
    preview = dispatch({'action': 'preview', 'plan_id': plan})
    with pytest.raises(ValueError, match='清单已变化'):
        dispatch({'action': 'apply', 'plan_id': plan, 'confirmed': True, 'moves': []})
    result = dispatch({'action': 'apply', 'plan_id': plan, 'confirmed': True, 'moves': preview['moves']})
    assert result['snapshot']['plan_id'] is None
    batch = result['snapshot']['history'][0]['id']
    assert all(Path(move['destination']).exists() for move in preview['moves'])
    dispatch({'action': 'undo', 'batch_id': batch, 'confirmed': True})
    assert len(list(gui.glob('*.md'))) == 2


def test_gui_edit_and_preferences(gui):
    proposal = dispatch({'action': 'scan', 'semantic': False})
    plan = proposal['snapshot']['plan_id']
    original = proposal['snapshot']['members'][0]['topic_key']
    edited = dispatch({'action': 'edit', 'plan_id': plan, 'command': 'rename', 'args': ['ELEC6008', 'My Course']})
    assert edited['snapshot']['members'][0]['topic'] == 'My Course'
    assert edited['snapshot']['members'][0]['topic_key'] == original
    settings = dispatch({'action': 'preferences', 'enabled': False, 'threshold': 0.95})
    assert settings['snapshot']['preferences']['auto_confirm_threshold'] == 0.95


def test_gui_previews_applies_and_dismisses_topics_independently(gui):
    for index in (1, 2):
        (gui / f'ELEC6103 Lecture {index}.md').write_text(f'Other {index}')
    proposal = dispatch({'action': 'scan', 'semantic': False})
    plan = proposal['snapshot']['plan_id']
    grouped = {}
    for member in proposal['snapshot']['members']:
        grouped.setdefault(member['topic_key'], []).append(member)
    assert len(grouped) == 2
    first, second = grouped

    preview = dispatch({'action': 'preview', 'plan_id': plan, 'topic_key': first})
    assert {move['topic_key'] for move in preview['moves']} == {first}
    with pytest.raises(ValueError, match='完整主题'):
        dispatch({
            'action': 'apply', 'plan_id': plan, 'confirmed': True,
            'moves': preview['moves'][:1],
        })
    applied = dispatch({
        'action': 'apply', 'plan_id': plan, 'confirmed': True, 'moves': preview['moves'],
    })
    assert applied['snapshot']['plan_id'] == plan
    assert all(member['applied'] for member in applied['snapshot']['members'] if member['topic_key'] == first)

    dismissed = dispatch({
        'action': 'edit', 'plan_id': plan, 'command': 'dismiss-topic', 'args': [second],
    })
    assert all(member['excluded'] for member in dismissed['snapshot']['members'] if member['topic_key'] == second)
    restored = dispatch({
        'action': 'edit', 'plan_id': plan, 'command': 'restore-topic', 'args': [second],
    })
    assert not any(member['excluded'] for member in restored['snapshot']['members'] if member['topic_key'] == second)
