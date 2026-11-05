# honk for LuCI

适用于 OpenWrt / ImmortalWrt 25.12 的 honk 管理界面，提供服务、配置、核心管理和系统日志页面。

应用不包含核心，从 [honk 官方 Release](https://github.com/daeuniverse/honk/releases) 下载静态 musl full 构建，支持 ARM64 和 x86_64。运行需要 root、Linux 6.12+、BTF 和 cgroup v2；软件包依赖见 [Makefile](Makefile)。

## 使用

1. 安装应用后重新登录 LuCI，进入 **服务 → honk**。首次安装不会启动服务或启用开机启动。
2. 在 **核心管理** 检查版本并安装核心。版本列表筛选官方最近 10 条发布中适合本机的 full 构建，包含预发布版。
3. 在 **配置** 编辑 `/etc/honk/config.dae`，按实际环境设置接口、订阅、节点和路由。配置示例见 [config.dae](root/etc/honk/config.dae)。
4. 使用 Geo 规则时，首次启动前通过 SSH 执行下方 [Geo 数据](#geo-数据)中的两条 curl 命令。
5. 保存配置，然后打开 **运行服务**。**开机启动**单独设置。

服务运行时保存新配置会发送热重载请求，停止时保持停止；未修改配置不会触发重载。请求成功不代表核心已接受新配置，请查看系统日志确认。下载来源、数据目录等需要重启才能生效的设置，修改后需手动停止再启动服务。`/etc/init.d/honk reload` 在配置路径不变时热重载，路径变化时由 procd 替换服务实例。编辑器只修改主配置文件，配置上限为 64 KiB。

## 核心管理

代理前缀默认为 `https://gh-proxy.com`，留空则直连 GitHub。前缀仅用于核心压缩包和 `SHA256SUMS`，GitHub API 始终直连。

下载后核对官方 API 摘要、`SHA256SUMS`、架构和版本。更新及回退保持原运行状态，新核心启动失败时尝试恢复旧核心。

| 文件 | 路径 |
| --- | --- |
| 当前核心 | `/usr/libexec/honk/honk-core` |
| 上一核心 | `/usr/libexec/honk/honk-core.old` |
| 主配置 | `/etc/honk/config.dae` |

核心由应用管理，独立于 APK 更新。回退只恢复核心文件，不回滚配置或数据库。安装前请卸载占用同名服务的其他 honk 软件包。

LuCI 编辑器管理文件配置，不使用 `--store db`。

## Geo 数据

默认配置使用：

```dae
global {
    data_dir: '/etc/honk/data'
}
```

Geo 文件保存为 `/etc/honk/data/geosite.dat` 和 `/etc/honk/data/geoip.dat`，状态数据库位于 `/etc/honk/data/state/honk.db`。核心按配置中的 `data_dir` 查找文件。自行修改 `data_dir` 时需同步调整下方下载路径。已有安装切换目录前，先停止服务，将旧目录中的 Geo 文件和 `state` 目录迁入新目录，再启动服务。

首次使用时，通过 SSH 在路由器上执行：

```sh
mkdir -p /etc/honk/data
curl -fL --retry 3 -o /etc/honk/data/geosite.dat 'https://gh-proxy.com/https://github.com/lauyv/rdat/raw/rel/geosite.dat'
curl -fL --retry 3 -o /etc/honk/data/geoip.dat 'https://gh-proxy.com/https://github.com/lauyv/cnip/raw/rel/chnroutes.dat'
```

确认两条命令均成功后再启动服务。仅设置 `assets.geodata` 下载来源不会补齐缺失文件；首次必须手动下载。

后续更新由 Honk 核心管理，示例配置已设置 `assets.geodata` 来源与直连下载路由。Native API 开启、状态数据库可用且允许配置写入并配置凭据时，核心默认每 24 小时检查已加载资源的更新，可通过原生面板调整设置或立即更新。启动不会立即下载；首次检查至少等待 5 分钟，再加最多 60 分钟随机延迟。

sysupgrade 保留整个 `/etc/honk/` 目录，包括配置、Geo 文件和状态数据库。

## 构建

将本目录放入匹配固件的源码树或 SDK，启用 LuCI feed 后执行：

```sh
make menuconfig
make package/luci-app-honk/compile V=s
```

GitHub Actions 的 **Release** 工作流仅发布 APK。输入与 Makefile 中 `PKG_VERSION` 一致的标签；发布说明从上次发布至今的完整 commit message 生成。应用版本独立于核心版本。

```sh
apk add --allow-untrusted /tmp/luci-app-honk-0.1.0-r1.apk
```

## 语法检查

```sh
node --check htdocs/luci-static/resources/view/honk/panel.js
```

实际安装和运行需在设备上验证。

## 许可证

本应用采用 [MIT](LICENSE)。honk 及 doona 使用各自上游许可证，APK 不包含其二进制。
