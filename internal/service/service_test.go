package service

import (
	"encoding/xml"
	"strings"
	"testing"
)

func TestLaunchdPlist(t *testing.T) {
	p := launchdPlist(Options{Binary: "/opt/homebrew/bin/tailmon", Port: 7020}, "/Users/x/Library/Logs/tailmon-agent.log")
	for _, want := range []string{
		"<string>com.bosphorify.tailmon</string>",
		"<string>/opt/homebrew/bin/tailmon</string>\n        <string>agent</string>\n    </array>",
		"<key>KeepAlive</key>", "tailmon-agent.log",
	} {
		if !strings.Contains(p, want) {
			t.Errorf("plist missing %q:\n%s", want, p)
		}
	}
	if strings.Contains(p, "--port") {
		t.Error("default port must not be passed")
	}
	if err := xml.Unmarshal([]byte(p), new(any)); err != nil {
		t.Errorf("plist is not well-formed XML: %v", err)
	}
	p = launchdPlist(Options{Binary: "/a & b/tailmon", Port: 7030}, "/l")
	if !strings.Contains(p, "<string>/a &amp; b/tailmon</string>") || !strings.Contains(p, "<string>7030</string>") {
		t.Errorf("escaping/port: %s", p)
	}
}

func TestSystemdUnit(t *testing.T) {
	u := systemdUnit(Options{Binary: "/usr/bin/tailmon", Port: 7020})
	if !strings.Contains(u, "ExecStart=/usr/bin/tailmon agent\n") || !strings.Contains(u, "Nice=10") ||
		!strings.Contains(u, "WantedBy=default.target") {
		t.Errorf("unit:\n%s", u)
	}
	u = systemdUnit(Options{Binary: "/home/me/my apps/tailmon", Port: 7021})
	if !strings.Contains(u, `ExecStart="/home/me/my apps/tailmon" agent --port 7021`) {
		t.Errorf("quoting: %s", u)
	}
}

func TestWindowsTaskXML(t *testing.T) {
	x := windowsTaskXML(Options{Binary: `C:\Tools\tailmon\tailmon.exe`, Port: 7020})
	var task struct {
		Settings struct {
			ExecutionTimeLimit         string
			DisallowStartIfOnBatteries bool
			StopIfGoingOnBatteries     bool
			Priority                   int
			MultipleInstancesPolicy    string
			RestartOnFailure           struct {
				Interval string
				Count    int
			}
		}
		Principals struct {
			Principal struct{ UserId string }
		}
		Actions struct {
			Exec struct{ Command, Arguments string }
		}
	}
	// The header says UTF-16 (what schtasks gets); parse the text as is.
	d := xml.NewDecoder(strings.NewReader(strings.Replace(x, `encoding="UTF-16"`, `encoding="UTF-8"`, 1)))
	if err := d.Decode(&task); err != nil {
		t.Fatal(err)
	}
	s := task.Settings
	if s.ExecutionTimeLimit != "PT0S" || s.DisallowStartIfOnBatteries || s.StopIfGoingOnBatteries ||
		s.Priority != 7 || s.MultipleInstancesPolicy != "IgnoreNew" ||
		s.RestartOnFailure.Interval != "PT1M" || s.RestartOnFailure.Count != 3 {
		t.Errorf("settings: %+v", s)
	}
	if task.Principals.Principal.UserId != "S-1-5-18" {
		t.Errorf("must run as SYSTEM: %q", task.Principals.Principal.UserId)
	}
	if task.Actions.Exec.Command != `C:\Tools\tailmon\tailmon.exe` || task.Actions.Exec.Arguments != "agent" {
		t.Errorf("action: %+v", task.Actions.Exec)
	}
}
