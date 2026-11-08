package service

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

func plistPath() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, "Library", "LaunchAgents", LaunchdLabel+".plist"), nil
}

func domain() string { return fmt.Sprintf("gui/%d", os.Getuid()) }

func install(o Options) error {
	if os.Geteuid() == 0 {
		return fmt.Errorf("run as your own user, not root: the agent is a per-user LaunchAgent")
	}
	path, err := plistPath()
	if err != nil {
		return err
	}
	home, _ := os.UserHomeDir()
	logPath := filepath.Join(home, "Library", "Logs", "tailmon-agent.log")
	for _, d := range []string{filepath.Dir(path), filepath.Dir(logPath)} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			return err
		}
	}
	if err := os.WriteFile(path, []byte(launchdPlist(o, logPath)), 0o644); err != nil {
		return err
	}
	bootout()
	if out, err := exec.Command("launchctl", "bootstrap", domain(), path).CombinedOutput(); err != nil {
		return fmt.Errorf("launchctl bootstrap: %v: %s", err, strings.TrimSpace(string(out)))
	}
	_ = exec.Command("launchctl", "kickstart", "-k", domain()+"/"+LaunchdLabel).Run()
	fmt.Printf("installed LaunchAgent %s\n  %s %s\n  log: %s\n", LaunchdLabel, o.Binary, strings.Join(o.agentArgs(), " "), logPath)
	return nil
}

// bootout unloads the job and waits until launchd has really dropped it:
// bootout returns early, and a bootstrap in that window fails with
// "5: Input/output error".
func bootout() {
	target := domain() + "/" + LaunchdLabel
	_ = exec.Command("launchctl", "bootout", target).Run()
	for i := 0; i < 50; i++ {
		if exec.Command("launchctl", "print", target).Run() != nil {
			return
		}
		time.Sleep(200 * time.Millisecond)
	}
}

func uninstall() error {
	path, err := plistPath()
	if err != nil {
		return err
	}
	bootout()
	if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
		return err
	}
	fmt.Printf("removed LaunchAgent %s (log kept at ~/Library/Logs/tailmon-agent.log)\n", LaunchdLabel)
	return nil
}

func status() string {
	path, _ := plistPath()
	if _, err := os.Stat(path); err != nil {
		return "service: not installed (no " + path + ")"
	}
	out, err := exec.Command("launchctl", "print", domain()+"/"+LaunchdLabel).Output()
	if err != nil {
		return "service: installed but not loaded (" + path + ")"
	}
	state, pid := "", ""
	for _, line := range strings.Split(string(out), "\n") {
		line = strings.TrimSpace(line)
		if v, ok := strings.CutPrefix(line, "state = "); ok && state == "" {
			state = v
		}
		if v, ok := strings.CutPrefix(line, "pid = "); ok && pid == "" {
			pid = v
		}
	}
	s := "service: LaunchAgent " + LaunchdLabel + " " + state
	if pid != "" {
		s += " (pid " + pid + ")"
	}
	return s
}
