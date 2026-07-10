package sample

import (
	"strings"
	"testing"
)

func TestClampTop(t *testing.T) {
	for _, tc := range []struct{ in, want int }{
		{-5, 1}, {0, 1}, {1, 1}, {5, 5}, {25, 25}, {26, 25}, {9999, 25},
	} {
		if got := ClampTop(tc.in); got != tc.want {
			t.Errorf("ClampTop(%d) = %d, want %d", tc.in, got, tc.want)
		}
	}
}

func TestShortCommand(t *testing.T) {
	if got := shortCommand("  /usr/bin/thing   --flag  x  "); got != "/usr/bin/thing --flag x" {
		t.Errorf("whitespace collapse: got %q", got)
	}
	// Rune safety: multi-byte characters at the truncation boundary must not
	// produce invalid UTF-8 (paths can contain non-ASCII, e.g. Kitaplarım).
	long := strings.Repeat("ı", commandMaxLen+50)
	got := shortCommand(long)
	if !strings.HasSuffix(got, "…") {
		t.Errorf("expected ellipsis suffix, got %q", got[len(got)-8:])
	}
	if r := []rune(got); len(r) != commandMaxLen {
		t.Errorf("truncated length = %d runes, want %d", len(r), commandMaxLen)
	}
	if strings.ContainsRune(got, '�') {
		t.Error("truncation produced invalid UTF-8 replacement char")
	}
}
