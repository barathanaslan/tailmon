package discover

import "testing"

// Shape captured from a real `tailscale status --json` (trimmed). Includes a
// phone (android) and an OS-less shared device, both of which must be skipped.
const statusFixture = `{
  "Self": {"HostName": "Barathans-MacStudio", "OS": "macOS", "Online": true,
           "TailscaleIPs": ["100.80.21.79", "fd7a:115c:a1e0::f101:1582"]},
  "Peer": {
    "k1": {"HostName": "Barathans-5070", "OS": "windows", "Online": false,
           "TailscaleIPs": ["100.95.91.27", "fd7a:115c:a1e0::973b:5b1c"]},
    "k2": {"HostName": "Nothing Phone (3a)", "OS": "android", "Online": true,
           "TailscaleIPs": ["100.117.110.66"]},
    "k3": {"HostName": "device-of-shared-to-user", "OS": "", "Online": false,
           "TailscaleIPs": ["100.64.206.65"]},
    "k4": {"HostName": "Barathan’s MacBook", "OS": "macOS", "Online": false,
           "TailscaleIPs": ["100.80.159.96"]}
  }
}`

func TestParseStatus(t *testing.T) {
	hosts, err := parseStatus([]byte(statusFixture))
	if err != nil {
		t.Fatal(err)
	}
	if len(hosts) != 3 {
		t.Fatalf("want 3 hosts (self + 2 agent-capable peers), got %d: %+v", len(hosts), hosts)
	}
	self := hosts[0]
	if !self.Self || self.Name != "barathans-macstudio" || self.IP != "100.80.21.79" || !self.Online {
		t.Errorf("self parsed wrong: %+v", self)
	}
	// Peers sorted by name: MacBook (unicode apostrophe) sorts after "barathans-5070".
	if hosts[1].Name != "barathans-5070" || hosts[1].OS != "windows" || hosts[1].Online {
		t.Errorf("cuda box parsed wrong: %+v", hosts[1])
	}
	if hosts[2].IP != "100.80.159.96" {
		t.Errorf("macbook parsed wrong: %+v", hosts[2])
	}
}

func TestParseStatusGarbage(t *testing.T) {
	if _, err := parseStatus([]byte("not json")); err == nil {
		t.Error("garbage must error")
	}
}
