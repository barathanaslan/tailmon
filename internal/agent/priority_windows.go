package agent

import "golang.org/x/sys/windows"

// lowerPriority puts the agent in BELOW_NORMAL_PRIORITY_CLASS: sampling must
// never compete with real work (training runs) on the host. Child processes
// (nvidia-smi) inherit the class.
func lowerPriority() error {
	return windows.SetPriorityClass(windows.CurrentProcess(), windows.BELOW_NORMAL_PRIORITY_CLASS)
}
