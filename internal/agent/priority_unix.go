//go:build !windows

package agent

import "golang.org/x/sys/unix"

// lowerPriority renices the agent by +10: sampling must never compete with
// real work (training runs) on the host.
func lowerPriority() error {
	return unix.Setpriority(unix.PRIO_PROCESS, 0, 10)
}
