package tui

import (
	"fmt"
	"strings"
	"time"

	"github.com/charmbracelet/lipgloss"

	"github.com/barathanaslan/tailmon/internal/aggregate"
	"github.com/barathanaslan/tailmon/internal/version"
)

var (
	styleTitle   = lipgloss.NewStyle().Bold(true)
	styleDim     = lipgloss.NewStyle().Faint(true)
	styleGood    = lipgloss.NewStyle().Foreground(lipgloss.Color("2"))
	styleWarn    = lipgloss.NewStyle().Foreground(lipgloss.Color("3"))
	styleBad     = lipgloss.NewStyle().Foreground(lipgloss.Color("1"))
	styleAccent  = lipgloss.NewStyle().Foreground(lipgloss.Color("6"))
	styleCard    = lipgloss.NewStyle().Border(lipgloss.RoundedBorder()).Padding(0, 1)
	styleCardSel = styleCard.BorderForeground(lipgloss.Color("6"))
	styleCardDim = styleCard.BorderForeground(lipgloss.Color("8"))
	sparkChars   = []rune("▁▂▃▄▅▆▇█")
)

func (m *model) View() string {
	var b strings.Builder
	b.WriteString(styleTitle.Render("tailmon "+version.Version) + styleDim.Render("  — tailnet monitor"))
	if m.paused {
		b.WriteString("  " + styleWarn.Render("[paused]"))
	}
	b.WriteString("\n")

	if len(m.rows) == 0 {
		b.WriteString("\n" + styleDim.Render("discovering tailnet hosts…") + "\n")
	}

	for i, r := range m.rows {
		b.WriteString(m.renderCard(r, i == m.selected))
		b.WriteString("\n")
	}

	if m.statusMsg != "" {
		b.WriteString(styleAccent.Render(m.statusMsg) + "\n")
	}

	b.WriteString(styleDim.Render("q quit · p pause · r refresh · j/k select") + "\n")
	return b.String()
}

func (m *model) renderCard(r *row, selected bool) string {
	inner := m.cardWidth() - 4 // border + padding
	var lines []string

	// Header: name, OS badge, state, uptime.
	name := styleTitle.Render(r.host.Name)
	badge := styleDim.Render(osBadge(r.host.OS))
	state := renderState(r)
	head := name + "  " + badge + "  " + state
	if r.stats != nil {
		head += styleDim.Render("  up " + humanDur(r.stats.UptimeSec))
	}
	lines = append(lines, head)

	switch {
	case r.status == aggregate.StatusLive && r.stats != nil:
		lines = append(lines, m.renderStatsLines(r, inner)...)
	case r.status == aggregate.StatusOffline:
		lines = append(lines, styleDim.Render("offline"))
	default: // no-agent
		hint := "online, no agent on :7020 — install tailmon agent on this host"
		if r.errMsg != "" {
			hint += styleDim.Render("  (" + trimErr(r.errMsg) + ")")
		}
		lines = append(lines, styleDim.Render(hint))
	}

	card := strings.Join(lines, "\n")
	style := styleCard
	if r.status != aggregate.StatusLive {
		style = styleCardDim
	}
	if selected {
		style = styleCardSel
	}
	return style.Width(m.cardWidth() - 2).Render(card)
}

func (m *model) renderStatsLines(r *row, inner int) []string {
	s := r.stats
	barW := 22
	var lines []string

	// CPU
	cpu := fmt.Sprintf("CPU %5.1f%% %s", s.CPU.Percent, bar(s.CPU.Percent, barW))
	if s.CPU.Load1 != nil {
		cpu += styleDim.Render(fmt.Sprintf("  load %.1f", *s.CPU.Load1))
	}
	cpu += styleDim.Render(fmt.Sprintf(" · %d cores", s.CPU.Cores))
	lines = append(lines, cpu)

	// RAM (+ pressure color)
	usedGB := float64(s.Mem.UsedMB) / 1024
	totalGB := float64(s.Mem.TotalMB) / 1024
	ramPct := 0.0
	if s.Mem.TotalMB > 0 {
		ramPct = 100 * float64(s.Mem.UsedMB) / float64(s.Mem.TotalMB)
	}
	ram := fmt.Sprintf("RAM %5.1f/%.0f GB %s", usedGB, totalGB, bar(ramPct, barW))
	if s.Mem.Pressure != nil {
		ram += " " + pressureStyle(*s.Mem.Pressure).Render(*s.Mem.Pressure)
	}
	if s.Mem.SwapUsedMB > 0 {
		ram += styleDim.Render(fmt.Sprintf(" · swap %dMB", s.Mem.SwapUsedMB))
	}
	lines = append(lines, ram)

	// GPU
	for _, g := range s.GPU {
		gpu := "GPU " + g.Name
		if g.UtilPct != nil {
			gpu += fmt.Sprintf(" %.0f%%", *g.UtilPct)
		} else {
			gpu += styleDim.Render(" util n/a")
		}
		if g.VRAMUsedMB != nil && g.VRAMTotalMB != nil {
			gpu += fmt.Sprintf(" · VRAM %.1f/%.1f GB", float64(*g.VRAMUsedMB)/1024, float64(*g.VRAMTotalMB)/1024)
		}
		if g.TempC != nil {
			gpu += fmt.Sprintf(" · %.0f°C", *g.TempC)
		}
		lines = append(lines, gpu)
	}

	// Disk (main volume) + the agent's own footprint (leak watch, dim).
	misc := ""
	if len(s.Disks) > 0 {
		d := s.Disks[0]
		misc = fmt.Sprintf("Disk %s %.0fG free of %.0fG", d.Mount, d.FreeGB, d.TotalGB)
	}
	misc += styleDim.Render(fmt.Sprintf("   agent %.1fMB · %d goroutines", s.Agent.RSSMB, s.Agent.Goroutines))
	lines = append(lines, misc)

	// Sparklines
	w := sparklineWidth
	if w > inner-12 {
		w = max(8, inner-12)
	}
	var buf [sparklineWidth]float64
	lines = append(lines,
		styleDim.Render("cpu ")+styleAccent.Render(sparkline(r.cpuHist.tail(buf[:w]))),
		styleDim.Render("ram ")+styleGood.Render(sparkline(r.ramHist.tail(buf[:w]))))
	return lines
}

func (m *model) cardWidth() int {
	w := m.width
	if w <= 0 {
		w = 100
	}
	if w > 110 {
		w = 110
	}
	return w
}

func renderState(r *row) string {
	switch r.status {
	case aggregate.StatusLive:
		return styleGood.Render("● live")
	case aggregate.StatusOffline:
		return styleDim.Render("○ offline")
	default:
		return styleWarn.Render("◌ no agent")
	}
}

func pressureStyle(p string) lipgloss.Style {
	switch p {
	case "critical":
		return styleBad
	case "warn":
		return styleWarn
	default:
		return styleGood
	}
}

// bar renders pct (0-100) as a fixed-width block bar.
func bar(pct float64, width int) string {
	if pct < 0 {
		pct = 0
	}
	if pct > 100 {
		pct = 100
	}
	filled := int(pct/100*float64(width) + 0.5)
	return strings.Repeat("█", filled) + strings.Repeat("░", width-filled)
}

// sparkline maps 0-100 values onto ▁▂▃▄▅▆▇█ (fixed scale so hosts compare).
func sparkline(vals []float64) string {
	if len(vals) == 0 {
		return ""
	}
	var b strings.Builder
	for _, v := range vals {
		idx := int(v / 100 * float64(len(sparkChars)-1))
		if idx < 0 {
			idx = 0
		}
		if idx >= len(sparkChars) {
			idx = len(sparkChars) - 1
		}
		b.WriteRune(sparkChars[idx])
	}
	return b.String()
}

func osBadge(os string) string {
	switch strings.ToLower(os) {
	case "macos", "darwin":
		return "[macOS]"
	case "windows":
		return "[win]"
	case "linux":
		return "[linux]"
	}
	return "[?]"
}

func humanDur(sec uint64) string {
	d := time.Duration(sec) * time.Second
	days := int(d.Hours()) / 24
	hours := int(d.Hours()) % 24
	mins := int(d.Minutes()) % 60
	if days > 0 {
		return fmt.Sprintf("%dd%dh", days, hours)
	}
	if hours > 0 {
		return fmt.Sprintf("%dh%dm", hours, mins)
	}
	return fmt.Sprintf("%dm", mins)
}

func trimErr(s string) string {
	if len(s) > 60 {
		return s[:57] + "…"
	}
	return s
}
