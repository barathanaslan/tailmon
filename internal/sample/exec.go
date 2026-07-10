package sample

import (
	"bytes"
	"context"
	"io"
	"os/exec"
	"time"
)

const execTimeout = 2 * time.Second

// runCmd runs a subprocess with a hard 2s timeout, /dev/null stdin, and
// discarded stderr. cmd.Run waits, so the child is always reaped.
func runCmd(ctx context.Context, name string, args ...string) ([]byte, error) {
	cctx, cancel := context.WithTimeout(ctx, execTimeout)
	defer cancel()
	cmd := exec.CommandContext(cctx, name, args...)
	cmd.Stdin = nil // child reads from the null device, never our stdin
	var out bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = io.Discard
	if err := cmd.Run(); err != nil {
		return nil, err
	}
	return out.Bytes(), nil
}
