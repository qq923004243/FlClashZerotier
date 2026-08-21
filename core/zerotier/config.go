package zerotier

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
)

// File names inside the app home dir (constant.Path.HomeDir() on Android).
const (
	ConfigFileName   = "zerotier.json"
	IdentityFileName = "zerotier-identity.secret"

	// CustomPlanetFileName holds the raw private planet (world) file bytes.
	// Written by the Flutter settings page, consumed by the engine before
	// node creation (see LoadCustomPlanet).
	CustomPlanetFileName = "zerotier-planet.custom"

	// PlanetMaxBytes mirrors FLCLASHTIER_ZT_PLANET_MAX in wrapper.h.
	PlanetMaxBytes = 8192

	// DefaultPort is the default ZeroTier wire UDP port.
	//
	// 9994 (not 9993) matches the official ZeroTier Android client, which
	// deliberately uses 9994 so it does not collide with a second ZeroTier
	// instance on the same device (desktop daemons bind 9993). Choosing the
	// same default as the official Android client also means our port is
	// already battle-tested against the same NAT/firewall patterns.
	//
	// IMPORTANT: the port is an invariant. A bind failure must NEVER fall
	// back to a random port (P0-1): silently changing the endpoint breaks
	// every peer's learned path and leaves the node unreachable (observed
	// 2026-08-19: i3 saw the node as RELAY -1 after a random-port fallback).
	DefaultPort = 9994
)

// RouteMode 决定 TUN 流量在 ZeroTier 与 Clash 之间的分工（单选，互斥）。
type RouteMode string

const (
	// RouteModeClash 纯 Clash：不启动 ZeroTier 引擎，行为与原版 FlClash 一致。
	RouteModeClash RouteMode = "clash"

	// RouteModeZerotier 纯 ZeroTier：全部流量优先走 ZeroTier（含 ZT 网络下发的
	// 默认路由），ZT 未覆盖的流量回落 mihomo 直连（不经代理链）。
	RouteModeZerotier RouteMode = "zerotier"

	// RouteModeCoexist 共存互不影响（默认）：命中 ZT Managed Routes 的流量走
	// ZeroTier 内网，其余流量交给 Clash 规则处理。
	RouteModeCoexist RouteMode = "coexist"

	// RouteModeClashOverZerotier Clash 走 ZeroTier：TUN 分流同共存模式，且
	// Clash 的出站拨号（代理服务器 / DIRECT 目标）若命中 ZT 内网路由，则改由
	// ZeroTier 承载——用于“通过 ZT 内网访问 Clash 节点”的场景。
	RouteModeClashOverZerotier RouteMode = "clash-over-zerotier"
)

// ParseRouteMode 归一化配置值；未知/空值回落到默认的共存模式。
func ParseRouteMode(s string) RouteMode {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case string(RouteModeClash):
		return RouteModeClash
	case string(RouteModeZerotier):
		return RouteModeZerotier
	case string(RouteModeClashOverZerotier):
		return RouteModeClashOverZerotier
	default:
		return RouteModeCoexist
	}
}

// activeRouteMode 记录当前 TUN 会话生效的路由模式，供拨号侧
// （lib.go 的 socket hook）实时查询，避免读文件。
var activeRouteMode atomic.Value // 存 RouteMode

// SetActiveRouteMode 由 TUN 启动路径在每次建链时调用（含禁用场景）。
func SetActiveRouteMode(m RouteMode) { activeRouteMode.Store(m) }

// ActiveRouteMode 返回当前生效的路由模式；TUN 未启动时为默认共存。
func ActiveRouteMode() RouteMode {
	if v, ok := activeRouteMode.Load().(RouteMode); ok {
		return v
	}
	return RouteModeCoexist
}

// Config is the content of <homeDir>/zerotier.json.
//
//	{
//	  "network-id": "b6079f73c6c0eb31",
//	  "port": 0,
//	  "use-custom-planet": true,
//	  "route-mode": "coexist"
//	}
//
// port is the local UDP port for ZeroTier wire traffic (0 = default 9994).
// Omit for default.
//
// use-custom-planet switches the node from the embedded official ZeroTier
// planet to the private planet stored in <homeDir>/zerotier-planet.custom
// (self-hosted root set, e.g. a self-built ztncui/planet network). The
// Flutter settings page imports the planet file; the engine installs it
// before creating the ZT node.
//
// route-mode selects the traffic split between ZeroTier and Clash
// (see RouteMode). Omit for the default coexist mode.
type Config struct {
	NetworkID       string    `json:"network-id"`
	Port            int       `json:"port,omitempty"`
	UseCustomPlanet bool      `json:"use-custom-planet,omitempty"`
	RouteMode       RouteMode `json:"route-mode,omitempty"`
}

// CustomPlanetPath returns the absolute path of the private planet file.
func CustomPlanetPath(homeDir string) string {
	return filepath.Join(homeDir, CustomPlanetFileName)
}

// LoadConfig reads <homeDir>/zerotier.json. A missing file means ZeroTier is
// disabled: (nil, nil). Parse/IO errors are returned so the caller can fall
// back to the plain mihomo pump.
func LoadConfig(homeDir string) (*Config, error) {
	if homeDir == "" {
		return nil, nil
	}
	p := filepath.Join(homeDir, ConfigFileName)
	data, err := os.ReadFile(p)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	cfg := &Config{}
	if err := json.Unmarshal(data, cfg); err != nil {
		return nil, err
	}
	cfg.NetworkID = strings.TrimSpace(cfg.NetworkID)
	cfg.RouteMode = ParseRouteMode(string(cfg.RouteMode))
	return cfg, nil
}

// Enabled reports whether ZeroTier should be started (network-id present).
func (c *Config) Enabled() bool { return c != nil && c.NetworkID != "" }

// LoadCustomPlanet reads and validates the private planet file. A missing
// file returns (nil, nil) so callers can distinguish "not imported yet"
// from "corrupt". Validation mirrors the official world file format: first
// byte must be 0x01 (world type = planet) and the file must fit within
// PlanetMaxBytes (the C wrapper enforces the same limits).
func LoadCustomPlanet(homeDir string) ([]byte, error) {
	if homeDir == "" {
		return nil, nil
	}
	data, err := os.ReadFile(CustomPlanetPath(homeDir))
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	if len(data) == 0 {
		return nil, errors.New("zerotier: planet file is empty")
	}
	if data[0] != 0x01 {
		return nil, errors.New("zerotier: invalid planet file (first byte must be 0x01)")
	}
	if len(data) > PlanetMaxBytes {
		return nil, errors.New("zerotier: planet file too large")
	}
	return data, nil
}

// ParseNWID converts a 16-hex-digit network ID (with or without 0x prefix).
func ParseNWID(s string) (uint64, error) {
	s = strings.TrimPrefix(strings.TrimSpace(s), "0x")
	if len(s) != 16 {
		return 0, errors.New("zerotier: network-id must be 16 hex digits")
	}
	v, err := strconv.ParseUint(s, 16, 64)
	if err != nil {
		return 0, err
	}
	if v == 0 {
		return 0, errors.New("zerotier: network-id cannot be zero")
	}
	return v, nil
}
