// Package tui is the bubbletea monitor: one card per tailnet host showing
// live resource usage. Monitor-only — no kill/tmux/control, and deliberately
// NO power controls: waking/shutting the CUDA box happens outside tailmon
// (`cuda on`/`cuda off`), per the owner's explicit preference (2026-07-10).
//
// Anti-leak rules honored here: fixed-size ring buffers (120 slots per host,
// allocated once), 800ms request timeouts, 10s probe backoff for hosts
// without an agent, and an in-flight guard so retries never stack.
package tui

import (
	"context"
	"net/http"
	"os"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/barathanaslan/tailmon/internal/agent"
	"github.com/barathanaslan/tailmon/internal/aggregate"
	"github.com/barathanaslan/tailmon/internal/discover"
	"github.com/barathanaslan/tailmon/internal/sample"
)

const (
	refreshInterval  = 2 * time.Second
	probeBackoff     = 10 * time.Second
	discoverInterval = 10 * time.Second
	historySlots     = 120
	sparklineWidth   = 40
)

// ring is a fixed-capacity history buffer — allocated once, never grows.
type ring struct {
	buf  [historySlots]float64
	head int
	n    int
}

func (r *ring) push(v float64) {
	r.buf[r.head] = v
	r.head = (r.head + 1) % historySlots
	if r.n < historySlots {
		r.n++
	}
}

// tail writes the newest k values (oldest first) into dst and returns the
// filled prefix. dst bounds the work: no allocation beyond the caller's.
func (r *ring) tail(dst []float64) []float64 {
	k := len(dst)
	if k > r.n {
		k = r.n
	}
	start := (r.head - k + 2*historySlots) % historySlots
	for i := 0; i < k; i++ {
		dst[i] = r.buf[(start+i)%historySlots]
	}
	return dst[:k]
}

type row struct {
	host      discover.Host
	status    string // aggregate.Status*
	stats     *sample.Stats
	errMsg    string
	cpuHist   ring
	ramHist   ring
	inFlight  bool
	nextProbe time.Time
}

type model struct {
	ctx          context.Context
	client       *http.Client
	rows         []*row
	selected     int
	paused       bool
	statusMsg    string
	tsMissing    bool
	lastDiscover time.Time
	discovering  bool
	width        int
}

type (
	tickMsg       time.Time
	discoveredMsg struct {
		hosts []discover.Host
		err   error
	}
	statsMsg struct {
		name  string
		stats *sample.Stats
		err   error
	}
)

// Run starts the TUI and blocks until quit. The derived context is canceled
// on exit so in-flight requests die too.
func Run(ctx context.Context) error {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	m := newModel(ctx)
	p := tea.NewProgram(m, tea.WithAltScreen(), tea.WithContext(ctx))
	_, err := p.Run()
	if ctx.Err() != nil || err == tea.ErrProgramKilled {
		return nil // interrupted: still a clean exit
	}
	return err
}

func newModel(ctx context.Context) *model {
	return &model{ctx: ctx, client: aggregate.NewClient(), width: 100}
}

func (m *model) Init() tea.Cmd {
	m.discovering = true
	return tea.Batch(discoverCmd(m.ctx), tickCmd())
}

func tickCmd() tea.Cmd {
	return tea.Tick(refreshInterval, func(t time.Time) tea.Msg { return tickMsg(t) })
}

func discoverCmd(ctx context.Context) tea.Cmd {
	return func() tea.Msg {
		hosts, err := discover.Hosts(ctx)
		return discoveredMsg{hosts, err}
	}
}

func (m *model) fetchCmd(r *row) tea.Cmd {
	r.inFlight = true
	name, ip, self := r.host.Name, r.host.IP, r.host.Self
	ctx, client := m.ctx, m.client
	return func() tea.Msg {
		if self {
			// Prefer the installed local agent (its self-stats are the real
			// deployed footprint); fall back to sampling in-process.
			if s, err := aggregate.FetchStats(ctx, client, "127.0.0.1", agent.DefaultPort, 0); err == nil {
				return statsMsg{name, s, nil}
			}
			s, err := sample.Collect(ctx)
			return statsMsg{name, s, err}
		}
		s, err := aggregate.FetchStats(ctx, client, ip, agent.DefaultPort, 0)
		return statsMsg{name, s, err}
	}
}

func (m *model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width = msg.Width
		return m, nil

	case tea.KeyMsg:
		return m.handleKey(msg)

	case tickMsg:
		cmds := []tea.Cmd{tickCmd()}
		if !m.paused {
			cmds = append(cmds, m.refreshCmds(false)...)
		}
		return m, tea.Batch(cmds...)

	case discoveredMsg:
		m.discovering = false
		m.lastDiscover = time.Now()
		if msg.err != nil {
			m.tsMissing = true
			if len(m.rows) == 0 {
				// Degrade gracefully: monitor localhost only.
				r := &row{host: discover.Host{Name: localHostname(), Self: true, Online: true}, status: aggregate.StatusNoAgent}
				m.rows = []*row{r}
				m.statusMsg = "tailscale CLI not found — monitoring localhost only"
				return m, m.fetchCmd(r)
			}
			return m, nil
		}
		m.tsMissing = false
		cmds := m.mergeHosts(msg.hosts)
		return m, tea.Batch(cmds...)

	case statsMsg:
		m.applyStats(msg)
		return m, nil
	}
	return m, nil
}

func (m *model) handleKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "q", "ctrl+c":
		return m, tea.Quit
	case "p":
		m.paused = !m.paused
		if m.paused {
			m.statusMsg = "paused"
		} else {
			m.statusMsg = ""
		}
	case "r":
		m.statusMsg = ""
		m.discovering = true
		cmds := append(m.refreshCmds(true), discoverCmd(m.ctx))
		return m, tea.Batch(cmds...)
	case "j", "down":
		if m.selected < len(m.rows)-1 {
			m.selected++
		}
	case "k", "up":
		if m.selected > 0 {
			m.selected--
		}
	}
	return m, nil
}

// refreshCmds decides which hosts to query this tick. live hosts refresh
// every tick; online hosts without an agent are probed on the 10s backoff;
// offline hosts are left to discovery. force resets backoff (the `r` key).
func (m *model) refreshCmds(force bool) []tea.Cmd {
	now := time.Now()
	var cmds []tea.Cmd
	for _, r := range m.rows {
		if r.inFlight {
			continue // never stack retries
		}
		switch {
		case r.host.Self:
			cmds = append(cmds, m.fetchCmd(r))
		case r.status == aggregate.StatusLive:
			cmds = append(cmds, m.fetchCmd(r))
		case r.host.Online && (force || now.After(r.nextProbe)):
			cmds = append(cmds, m.fetchCmd(r))
		}
	}
	if time.Since(m.lastDiscover) > discoverInterval && !m.discovering {
		m.discovering = true
		cmds = append(cmds, discoverCmd(m.ctx))
	}
	return cmds
}

// mergeHosts reconciles a discovery result with existing rows, preserving
// per-host history. Returns fetch cmds for rows that have never been sampled.
func (m *model) mergeHosts(hosts []discover.Host) []tea.Cmd {
	existing := make(map[string]*row, len(m.rows))
	for _, r := range m.rows {
		existing[r.host.Name] = r
	}
	rows := make([]*row, 0, len(hosts))
	var cmds []tea.Cmd
	for _, h := range hosts {
		r, ok := existing[h.Name]
		if !ok {
			r = &row{host: h}
			if !h.Online {
				r.status = aggregate.StatusOffline
			} else {
				r.status = aggregate.StatusNoAgent
				cmds = append(cmds, m.fetchCmd(r))
			}
			rows = append(rows, r)
			continue
		}
		wasOnline := r.host.Online
		r.host = h
		if !h.Online && !h.Self {
			r.status = aggregate.StatusOffline
			r.stats = nil
		} else if h.Online && !wasOnline {
			r.status = aggregate.StatusNoAgent
			r.nextProbe = time.Time{}
			if !r.inFlight {
				cmds = append(cmds, m.fetchCmd(r))
			}
		}
		rows = append(rows, r)
	}
	m.rows = rows
	if m.selected >= len(m.rows) {
		m.selected = max(0, len(m.rows)-1)
	}
	return cmds
}

func (m *model) applyStats(msg statsMsg) {
	for _, r := range m.rows {
		if r.host.Name != msg.name {
			continue
		}
		r.inFlight = false
		if msg.err != nil {
			r.errMsg = msg.err.Error()
			if r.status == aggregate.StatusLive {
				r.status = aggregate.StatusNoAgent
			}
			r.nextProbe = time.Now().Add(probeBackoff)
			return
		}
		r.errMsg = ""
		r.status = aggregate.StatusLive
		r.stats = msg.stats
		r.cpuHist.push(msg.stats.CPU.Percent)
		if msg.stats.Mem.TotalMB > 0 {
			r.ramHist.push(100 * float64(msg.stats.Mem.UsedMB) / float64(msg.stats.Mem.TotalMB))
		}
		return
	}
}

func (m *model) currentRow() *row {
	if m.selected < 0 || m.selected >= len(m.rows) {
		return nil
	}
	return m.rows[m.selected]
}

func localHostname() string {
	h, err := os.Hostname()
	if err != nil {
		return "localhost"
	}
	h, _, _ = strings.Cut(h, ".")
	return strings.ToLower(h)
}

