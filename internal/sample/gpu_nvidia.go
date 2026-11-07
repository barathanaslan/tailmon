package sample

import (
	"context"
	"strconv"
	"strings"
)

var nvidiaSMIQueryArgs = []string{
	"--query-gpu=name,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw,power.limit,fan.speed",
	"--format=csv,noheader,nounits",
}

// queryNvidiaSMI tries each candidate nvidia-smi path in order and parses the
// first one that runs. Returns an empty (non-nil) slice when none work.
func queryNvidiaSMI(ctx context.Context, candidates []string) []GPU {
	for _, bin := range candidates {
		out, err := runCmd(ctx, bin, nvidiaSMIQueryArgs...)
		if err != nil {
			continue
		}
		if gpus := parseNvidiaSMI(string(out)); len(gpus) > 0 {
			return gpus
		}
	}
	return []GPU{}
}

// parseNvidiaSMI parses `nvidia-smi --format=csv,noheader,nounits` output:
//
//	NVIDIA GeForce RTX 5070 Ti, 3, 512, 16303, 41, 18.52, 300.00, 0
//
// Columns 6-8 (power draw W, power limit W, fan %) are optional so output
// from the 5-column query still parses. "[N/A]" or unparsable fields become
// null, never fabricated.
func parseNvidiaSMI(out string) []GPU {
	gpus := []GPU{}
	for _, line := range strings.Split(out, "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		fields := strings.Split(line, ",")
		if len(fields) != 5 && len(fields) != 8 {
			continue
		}
		for i := range fields {
			fields[i] = strings.TrimSpace(fields[i])
		}
		g := GPU{Name: fields[0]}
		if v, ok := parseSMIFloat(fields[1]); ok {
			g.UtilPct = &v
		}
		if v, ok := parseSMIUint(fields[2]); ok {
			g.VRAMUsedMB = &v
		}
		if v, ok := parseSMIUint(fields[3]); ok {
			g.VRAMTotalMB = &v
		}
		if v, ok := parseSMIFloat(fields[4]); ok {
			g.TempC = &v
		}
		if len(fields) == 8 {
			if v, ok := parseSMIFloat(fields[5]); ok {
				v = round1(v)
				g.PowerW = &v
			}
			if v, ok := parseSMIFloat(fields[6]); ok {
				v = round1(v)
				g.PowerLimitW = &v
			}
			if v, ok := parseSMIFloat(fields[7]); ok {
				g.FanPct = &v
			}
		}
		gpus = append(gpus, g)
	}
	return gpus
}

func parseSMIFloat(s string) (float64, bool) {
	v, err := strconv.ParseFloat(s, 64)
	if err != nil {
		return 0, false
	}
	return v, true
}

func parseSMIUint(s string) (uint64, bool) {
	v, err := strconv.ParseUint(s, 10, 64)
	if err != nil {
		return 0, false
	}
	return v, true
}
