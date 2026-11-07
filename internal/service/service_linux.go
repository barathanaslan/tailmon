package service

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

func unitPath() (string, error) {
	dir := os.Getenv("XDG_CONFIG_HOME")
	if dir == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return "", err
		}
		dir = filepath.Join(home, ".config")
	}
	return filepath.Join(dir, "systemd", "user", UnitName), nil
}

func systemctl(args ...string) error {
	out, err := exec.Command("systemctl", append([]string{"--user"}, args...)...).CombinedOutput()
	if err != nil {
		return fmt.Errorf("systemctl --user %s: %v: %s", strings.Join(args, " "), err, strings.TrimSpace(string(out)))
	}
	return nil
}

func install(o Options) error {
	if os.Geteuid() == 0 {
		return fmt.Errorf("run as your own user, not root: the agent is a systemd user unit")
	}
	path, err := unitPath()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	if err := os.WriteFile(path, []byte(systemdUnit(o)), 0o644); err != nil {
		return err
	}
	if err := systemctl("daemon-reload"); err != nil {
		return err
	}
	if err := systemctl("enable", UnitName); err != nil {
		return err
	}
	if err := systemctl("restart", UnitName); err != nil {
		return err
	}
	fmt.Printf("installed systemd user unit %s\n  %s %s\n  logs: journalctl --user -u tailmon\n", path, o.Binary, strings.Join(o.agentArgs(), " "))
	fmt.Println("  to keep it running while you are logged out: loginctl enable-linger $USER")
	return nil
}

func uninstall() error {
	path, err := unitPath()
	if err != nil {
		return err
	}
	_ = systemctl("disable", "--now", UnitName)
	if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
		return err
	}
	_ = systemctl("daemon-reload")
	fmt.Printf("removed systemd user unit %s\n", path)
	return nil
}

func status() string {
	path, _ := unitPath()
	out, _ := exec.Command("systemctl", "--user", "is-active", UnitName).Output()
	state := strings.TrimSpace(string(out))
	if _, err := os.Stat(path); err != nil {
		if state == "active" {
			return "service: " + UnitName + " active (unit installed by a package)"
		}
		return "service: not installed (no " + path + ")"
	}
	return "service: " + UnitName + " " + state
}
