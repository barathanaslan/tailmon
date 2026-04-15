from collector.sources.ssh_sessions import SSHCollector


def test_ssh_collector_runs_on_real_psutil():
    coll = SSHCollector()
    sessions = coll.sessions({})  # empty peer map is fine
    # We don't assert any particular session exists; just that the walker
    # returns a list and doesn't raise.
    assert isinstance(sessions, list)
