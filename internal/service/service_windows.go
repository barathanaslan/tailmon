package service

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"unicode/utf16"

	"golang.org/x/sys/windows"
)

func elevated() bool {
	return windows.GetCurrentProcessToken().IsElevated()
}

func schtasks(args ...string) (string, error) {
	out, err := exec.Command("schtasks", args...).CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("schtasks %s: %v: %s", strings.Join(args, " "), err, strings.TrimSpace(string(out)))
	}
	return string(out), nil
}

func install(o Options) error {
	if !elevated() {
		return fmt.Errorf("run from an elevated (Administrator) shell: the agent is an ONSTART task running as SYSTEM")
	}
	// schtasks /xml wants UTF-16 LE with a BOM.
	f, err := os.CreateTemp("", "tailmon-task-*.xml")
	if err != nil {
		return err
	}
	tmp := f.Name()
	defer os.Remove(tmp)
	u := utf16.Encode([]rune(windowsTaskXML(o)))
	buf := make([]byte, 2, 2+2*len(u))
	buf[0], buf[1] = 0xFF, 0xFE
	for _, c := range u {
		buf = append(buf, byte(c), byte(c>>8))
	}
	if _, err := f.Write(buf); err != nil {
		f.Close()
		return err
	}
	f.Close()

	_, _ = schtasks("/end", "/tn", TaskName) // replace a running agent cleanly
	if _, err := schtasks("/create", "/f", "/tn", TaskName, "/xml", tmp); err != nil {
		return err
	}
	if _, err := schtasks("/run", "/tn", TaskName); err != nil {
		return err
	}
	fmt.Printf("installed scheduled task %s (ONSTART, SYSTEM, below-normal priority)\n  %s %s\n",
		TaskName, o.Binary, strings.Join(o.agentArgs(), " "))
	if strings.Contains(strings.ToLower(filepath.ToSlash(o.Binary)), "/scoop/") {
		fmt.Println("  note: runs from your scoop folder; re-run this after `scoop update tailmon` only if the path changed")
	}
	return nil
}

func uninstall() error {
	if !elevated() {
		return fmt.Errorf("run from an elevated (Administrator) shell")
	}
	_, _ = schtasks("/end", "/tn", TaskName)
	if _, err := schtasks("/delete", "/f", "/tn", TaskName); err != nil {
		if strings.Contains(err.Error(), "cannot find") || strings.Contains(err.Error(), "does not exist") {
			fmt.Println("no scheduled task " + TaskName)
			return nil
		}
		return err
	}
	fmt.Println("removed scheduled task " + TaskName)
	return nil
}

func status() string {
	out, err := schtasks("/query", "/tn", TaskName, "/fo", "LIST")
	if err != nil {
		return "service: scheduled task " + TaskName + " not found"
	}
	st := ""
	for _, line := range strings.Split(out, "\n") {
		if k, v, ok := strings.Cut(line, ":"); ok && strings.TrimSpace(k) == "Status" {
			st = strings.TrimSpace(v)
		}
	}
	return "service: scheduled task " + TaskName + " " + st
}
