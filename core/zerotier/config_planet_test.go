package zerotier

import (
	"os"
	"path/filepath"
	"testing"
)

// Private planet file loading (pure Go; no ZT core needed).

func TestLoadCustomPlanetMissing(t *testing.T) {
	data, err := LoadCustomPlanet(t.TempDir())
	if err != nil {
		t.Fatalf("missing file must be (nil, nil), got err=%v", err)
	}
	if data != nil {
		t.Fatalf("missing file must return nil data")
	}
}

func TestLoadCustomPlanetValid(t *testing.T) {
	dir := t.TempDir()
	// Minimal fake world file: type byte 0x01 + payload.
	content := append([]byte{0x01}, make([]byte, 569)...)
	if err := os.WriteFile(filepath.Join(dir, CustomPlanetFileName), content, 0600); err != nil {
		t.Fatal(err)
	}
	data, err := LoadCustomPlanet(dir)
	if err != nil {
		t.Fatalf("valid planet rejected: %v", err)
	}
	if len(data) != len(content) || data[0] != 0x01 {
		t.Fatalf("planet data mismatch: len=%d first=%#x", len(data), data[0])
	}
}

func TestLoadCustomPlanetBadHeader(t *testing.T) {
	dir := t.TempDir()
	// 0x02 = moon world type; must be rejected (this slot is planet-only).
	if err := os.WriteFile(filepath.Join(dir, CustomPlanetFileName), []byte{0x02, 0x00}, 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadCustomPlanet(dir); err == nil {
		t.Fatalf("moon-type world file must be rejected")
	}
}

func TestLoadCustomPlanetEmpty(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, CustomPlanetFileName), nil, 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadCustomPlanet(dir); err == nil {
		t.Fatalf("empty planet file must be rejected")
	}
}

func TestLoadCustomPlanetTooLarge(t *testing.T) {
	dir := t.TempDir()
	big := make([]byte, PlanetMaxBytes+1)
	big[0] = 0x01
	if err := os.WriteFile(filepath.Join(dir, CustomPlanetFileName), big, 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadCustomPlanet(dir); err == nil {
		t.Fatalf("oversized planet file must be rejected")
	}
}

func TestConfigUseCustomPlanetRoundTrip(t *testing.T) {
	dir := t.TempDir()
	raw := []byte(`{"network-id":"b6079f73c6c0eb31","use-custom-planet":true}`)
	if err := os.WriteFile(filepath.Join(dir, ConfigFileName), raw, 0600); err != nil {
		t.Fatal(err)
	}
	cfg, err := LoadConfig(dir)
	if err != nil {
		t.Fatal(err)
	}
	if !cfg.Enabled() || !cfg.UseCustomPlanet {
		t.Fatalf("config parse mismatch: %+v", cfg)
	}
	// Legacy config without the flag must default to the official planet.
	raw = []byte(`{"network-id":"b6079f73c6c0eb31"}`)
	if err := os.WriteFile(filepath.Join(dir, ConfigFileName), raw, 0600); err != nil {
		t.Fatal(err)
	}
	cfg, err = LoadConfig(dir)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.UseCustomPlanet {
		t.Fatalf("legacy config must not enable custom planet: %+v", cfg)
	}
}
