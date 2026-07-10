package sample

import "testing"

func TestParseIoregDeviceUtil(t *testing.T) {
	// Captured from a real M3 Ultra: PerformanceStatistics is one long line.
	out := `"PerformanceStatistics" = {"In use system memory (driver)"=0,"Alloc system memory"=7113703424,"Tiler Utilization %"=7,"Renderer Utilization %"=6,"Device Utilization %"=7,"SplitSceneCount"=0}`
	v, ok := parseIoregDeviceUtil(out)
	if !ok || v != 7 {
		t.Errorf("got %v, %v; want 7, true", v, ok)
	}
	if _, ok := parseIoregDeviceUtil(`"SomethingElse" = 3`); ok {
		t.Error("absent key must report not-ok (util_pct null)")
	}
}

func TestPressureFromFreePct(t *testing.T) {
	cases := []struct {
		out  string
		want string // "" = nil
	}{
		{"System-wide memory free percentage: 94%\n", "normal"},
		{"System-wide memory free percentage: 21%\n", "normal"},
		{"System-wide memory free percentage: 20%\n", "warn"},
		{"System-wide memory free percentage: 10%\n", "warn"},
		{"System-wide memory free percentage: 9%\n", "critical"},
		{"no such line", ""},
	}
	for _, c := range cases {
		got := pressureFromFreePct(c.out)
		if c.want == "" {
			if got != nil {
				t.Errorf("%q: want nil, got %q", c.out, *got)
			}
			continue
		}
		if got == nil || *got != c.want {
			t.Errorf("%q: want %q, got %v", c.out, c.want, got)
		}
	}
}
