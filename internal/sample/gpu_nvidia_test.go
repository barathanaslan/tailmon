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
