package agent

import (
	"os"
	"testing"
)

// Keep the agent's persisted disk memory out of the real cache dir.
func TestMain(m *testing.M) {
	dir, _ := os.MkdirTemp("", "tailmon-state-")
	os.Setenv("TAILMON_STATE_DIR", dir)
	code := m.Run()
	os.RemoveAll(dir)
	os.Exit(code)
}
