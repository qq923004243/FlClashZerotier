<div align="center">

# FlClashTier

**FlClash + ZeroTier Core 双网络出口 — 单 Android VPN 内嵌 Mihomo 与 ZeroTier，支持私有 Planet**

在一个 Android VpnService 中，把 ZeroTier Core 与 Mihomo Core 作为两个并列的网络出口：
ZeroTier 管私网（ZT Managed Routes 网段），Mihomo 管代理/公网（DIRECT / PROXY）。

</div>

---

## 这是什么

普通 Android 设备（未 root）一次只能运行一个 VPN Service，因此 FlClash（Clash 代理）与
ZeroTier（虚拟组网）无法同时工作 —— 而现实里你经常需要**通过 FlClash 代理去访问
ZeroTier 组网内的设备**，或者反过来。

FlClashTier 在 FlClash 的 TUN 与 Mihomo 内核之间插入一个 **Packet Pump（分流层）**，
把 ZeroTier Core 作为第二个出口接进来，实现单 VPN 双出口：

```
Android VpnService
│  real TUN fd
▼
┌────────────┐
│ Flow Router│  ← 命中 ZT Managed Routes → ZeroTier Core（内网）
│ (Pump)     │  ← 其余流量             → socketpair → Mihomo（代理/直连）
└────────────┘
```

- 不改 Mihomo、不改 Android VpnService —— 只加一层很薄的适配
- ZeroTier 物理 UDP socket 经 `VpnService.protect()` 绕过 TUN，防止环路
- ZT 边界做 SNAT/DNAT（TUN 网段在 ZT 网络内不可路由）

## 私有 Planet（自建 ZeroTier 根服务器）

与多数集成方案不同，FlClashTier **不强制使用 ZeroTier 官方公共服务**。如果你的
ZeroTier 网络部署在自建 planet（自托管根服务器，例如自建的 ztncui / 私有 World）上：

1. 打开 App 的 **设置 → ZeroTier**
2. 在「私有 Planet」区域选择 **从文件导入 Planet** 或 **从 URL 导入 Planet**
3. 导入你的 `planet` 文件并打开 **使用私有 Planet** 开关
4. 填写 Network ID，重启 VPN

之后 ZT 节点只会连接你的私有根服务器。planet 文件校验与
[ZerotierFix](https://github.com/gmij/ZerotierFix) 相同：首字节必须为 `0x01`
（World type = planet），大小不超过 8KB；引擎启动时装入 ZeroTier Core，
且在引擎停止后自动恢复官方 planet，互不污染。

配置文件（`HomeDir/zerotier.json`）：

```json
{
  "network-id": "你的16位十六进制网络ID",
  "use-custom-planet": true
}
```

planet 文件保存在 `HomeDir/zerotier-planet.custom`。
清空 `network-id` 即完全禁用 ZeroTier，回到纯 Mihomo 模式。

## 使用步骤

1. 在「配置文件」页导入 Clash 订阅/配置（首页出现启动按钮的前提）
2. 在「设置 → ZeroTier」填写 Network ID（自建网络还需导入私有 planet）
3. 启动 VPN 并在控制器（ZeroTier Central 或自建控制器）授权本节点
4. 修改配置后重启 VPN 生效

命中 ZeroTier Managed Routes 网段的流量走 ZT 内网（可直接访问组网内设备），
其余流量照旧走 Mihomo 规则。注意：ZT 内网访问建议直接用 IP（DNS 解析受
mihomo dns-hijack 影响）。

## 构建

Android（arm64-v8a）：

```bash
# 初始化子模块（Clash.Meta 等）
git submodule update --init --recursive

# 构建 core（需要 Go + Android NDK；ZeroTier wrapper 会自动编译）
make core-android ARCH=arm64

# 构建 APK（需要 Flutter + Android SDK）
flutter build apk --release
```

仓库内置 GitHub Actions（`.github/workflows`），推送到 main 后自动产出 APK。

## 致谢与上游

- [chen08209/FlClash](https://github.com/chen08209/FlClash) — 上游 FlClash（GPL-3.0）
- [ximalu/FlClashTier](https://github.com/ximalu/FlClashTier) — 架构设计文档（M0/M1/M2）
- [ximalu/FlClash](https://github.com/ximalu/FlClash) — 本仓库的代码基线（M0 pump + M1 ZeroTier 分流）
- [gmij/ZerotierFix](https://github.com/gmij/ZerotierFix) — 私有 planet 导入方案参考
- [zerotier/ZeroTierOne](https://github.com/zerotier/ZeroTierOne) — ZeroTier Core（BSL 1.1）
- [metacubex/mihomo](https://github.com/metacubex/mihomo) / [sagernet/sing-tun](https://github.com/sagernet/sing-tun)

## 许可证

- FlClash / FlClashTier 部分：GPL-3.0（fork 须保持 GPL）
- ZeroTier Core：BSL 1.1（个人/内部/学术免费；每个版本 4 年后转 Apache 2.0）
