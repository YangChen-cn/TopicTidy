import plistlib
from types import SimpleNamespace

import pytest

from downloads_organizer.embedding import NativeMacOSEncoder
from downloads_organizer.translation import NativeTranslationBackend
from downloads_organizer.scheduler import LaunchAgentScheduler


@pytest.mark.parametrize('backend,name', [(NativeMacOSEncoder, 'native-embedding'),
                                          (NativeTranslationBackend, 'native-translation')])
def test_bundle_helpers_never_compile(workspace, tmp_path, monkeypatch, backend, name):
    settings, _ = workspace
    monkeypatch.setattr('sys.platform', 'darwin')
    monkeypatch.setenv('TOPICTIDY_HELPERS', str(tmp_path))
    monkeypatch.setattr('subprocess.run', lambda *a, **kw: pytest.fail('must not compile bundled helper'))
    instance = backend(settings, prepare=False)
    assert not instance.is_prepared()
    with pytest.raises(RuntimeError, match='缺失'):
        instance.prepare()
    helper = tmp_path / name
    helper.write_text('#!/bin/sh\nexit 0\n')
    helper.chmod(0o755)
    assert instance.is_prepared()
    assert instance.prepare() == helper


def test_bundle_schedule_preserves_helpers_and_signature(workspace, tmp_path, monkeypatch):
    settings, _ = workspace
    monkeypatch.setattr('sys.platform', 'darwin')
    monkeypatch.setenv('TOPICTIDY_HELPERS', '/Applications/TopicTidy.app/Contents/Resources/helpers')
    scheduler = LaunchAgentScheduler(settings, plist_path=tmp_path / 'daily.plist',
                                    runner=lambda *a, **kw: SimpleNamespace(returncode=0, stdout='', stderr=''))
    scheduler.enable('09:00')
    payload = plistlib.loads(scheduler.plist_path.read_bytes())
    assert payload['ProgramArguments'][1:3] == ['-I', '-B']
    assert payload['EnvironmentVariables']['TOPICTIDY_HELPERS'].endswith('/helpers')
