package sample

import "testing"

func TestParseNvidiaSMI(t *testing.T) {
	out := "NVIDIA GeForce RTX 5070 Ti, 3, 512, 16303, 41\n"
	gpus := parseNvidiaSMI(out)
	if len(gpus) != 1 {
		t.Fatalf("want 1 gpu, got %d", len(gpus))
	}
	g := gpus[0]
	if g.Name != "NVIDIA GeForce RTX 5070 Ti" {
		t.Errorf("name = %q", g.Name)
	}
	if g.UtilPct == nil || *g.UtilPct != 3 {
		t.Errorf("util = %v", g.UtilPct)
	}
	if g.VRAMUsedMB == nil || *g.VRAMUsedMB != 512 {
		t.Errorf("vram used = %v", g.VRAMUsedMB)
	}
	if g.VRAMTotalMB == nil || *g.VRAMTotalMB != 16303 {
		t.Errorf("vram total = %v", g.VRAMTotalMB)
	}
	if g.TempC == nil || *g.TempC != 41 {
		t.Errorf("temp = %v", g.TempC)
	}
}

func TestParseNvidiaSMINotAvailableFields(t *testing.T) {
	out := "Some GPU, [N/A], [N/A], 8192, [N/A]\n"
	gpus := parseNvidiaSMI(out)
	if len(gpus) != 1 {
		t.Fatalf("want 1 gpu, got %d", len(gpus))
	}
	g := gpus[0]
	if g.UtilPct != nil || g.VRAMUsedMB != nil || g.TempC != nil {
		t.Errorf("[N/A] fields must be null: %+v", g)
	}
	if g.VRAMTotalMB == nil || *g.VRAMTotalMB != 8192 {
		t.Errorf("vram total = %v", g.VRAMTotalMB)
	}
}

func TestParseNvidiaSMIGarbage(t *testing.T) {
	if gpus := parseNvidiaSMI("not,csv\n\n"); len(gpus) != 0 {
		t.Errorf("garbage should parse to no gpus, got %+v", gpus)
	}
	if gpus := parseNvidiaSMI(""); gpus == nil || len(gpus) != 0 {
		t.Errorf("empty input should give empty non-nil slice, got %#v", gpus)
	}
}

func TestParseNvidiaSMIPowerFan(t *testing.T) {
	out := "NVIDIA GeForce RTX 5090, 97, 29081, 32607, 71, 548.27, 575.00, 62\n" +
		"Other GPU, 0, 10, 8192, 30, [N/A], [N/A], [N/A]\n"
	gpus := parseNvidiaSMI(out)
	if len(gpus) != 2 {
		t.Fatalf("want 2 gpus, got %d", len(gpus))
	}
	g := gpus[0]
	if g.PowerW == nil || *g.PowerW != 548.3 {
		t.Errorf("power = %v", g.PowerW)
	}
	if g.PowerLimitW == nil || *g.PowerLimitW != 575 {
		t.Errorf("power limit = %v", g.PowerLimitW)
	}
	if g.FanPct == nil || *g.FanPct != 62 {
		t.Errorf("fan = %v", g.FanPct)
	}
	if o := gpus[1]; o.PowerW != nil || o.PowerLimitW != nil || o.FanPct != nil {
		t.Errorf("[N/A] power/fan must be null: %+v", o)
	}
	if gpus[1].TempC == nil || *gpus[1].TempC != 30 {
		t.Errorf("temp = %v", gpus[1].TempC)
	}
}
