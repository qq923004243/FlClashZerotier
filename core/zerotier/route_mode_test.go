package zerotier

import (
	"os"
	"path/filepath"
	"testing"
)

func TestParseRouteMode(t *testing.T) {
	cases := []struct {
		in   string
		want RouteMode
	}{
		{"clash", RouteModeClash},
		{"zerotier", RouteModeZerotier},
		{"coexist", RouteModeCoexist},
		{"clash-over-zerotier", RouteModeClashOverZerotier},
		{" CLASH ", RouteModeClash},
		{"Clash-Over-ZeroTier", RouteModeClashOverZerotier},
		{"", RouteModeCoexist},
		{"bogus", RouteModeCoexist},
	}
	for _, c := range cases {
		if got := ParseRouteMode(c.in); got != c.want {
			t.Errorf("ParseRouteMode(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestLoadConfigRouteModeDefault(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, ConfigFileName)

	if err := os.WriteFile(p, []byte(`{"network-id":"b6079f73c6c0eb31"}`), 0o644); err != nil {
		t.Fatal(err)
	}
	cfg, err := LoadConfig(dir)
	if err != nil || cfg == nil {
		t.Fatalf("LoadConfig: %v", err)
	}
	if cfg.RouteMode != RouteModeCoexist {
		t.Errorf("missing route-mode should default to coexist, got %q", cfg.RouteMode)
	}

	if err := os.WriteFile(p, []byte(`{"network-id":"b6079f73c6c0eb31","route-mode":"clash-over-zerotier"}`), 0o644); err != nil {
		t.Fatal(err)
	}
	cfg, err = LoadConfig(dir)
	if err != nil || cfg == nil {
		t.Fatalf("LoadConfig: %v", err)
	}
	if cfg.RouteMode != RouteModeClashOverZerotier {
		t.Errorf("route-mode = %q, want clash-over-zerotier", cfg.RouteMode)
	}
}

func TestActiveRouteModeDefault(t *testing.T) {
	if ActiveRouteMode() == "" {
		t.Fatal("ActiveRouteMode must never be empty")
	}
	SetActiveRouteMode(RouteModeClashOverZerotier)
	if ActiveRouteMode() != RouteModeClashOverZerotier {
		t.Fatalf("ActiveRouteMode = %q, want clash-over-zerotier", ActiveRouteMode())
	}
	SetActiveRouteMode(RouteModeClash)
	if ActiveRouteMode() != RouteModeClash {
		t.Fatalf("ActiveRouteMode = %q, want clash", ActiveRouteMode())
	}
}

func TestRouteTableAllowDefault(t *testing.T) {
	rt := NewRouteTable()
	rt.Set([]Route{{Prefix: mustPrefix("0.0.0.0/0")}, {Prefix: mustPrefix("192.168.196.0/24")}})
	if rt.Count() != 1 {
		t.Fatalf("default route must be filtered by default, count=%d", rt.Count())
	}

	rt2 := NewRouteTable()
	rt2.SetAllowDefault(true)
	rt2.Set([]Route{{Prefix: mustPrefix("0.0.0.0/0")}, {Prefix: mustPrefix("192.168.196.0/24")}})
	if rt2.Count() != 2 {
		t.Fatalf("allow-default must keep 0.0.0.0/0, count=%d", rt2.Count())
	}
	if rt2.Match(mustAddr("8.8.8.8")) == nil {
		t.Fatal("default route must match arbitrary addresses when allowed")
	}
}
