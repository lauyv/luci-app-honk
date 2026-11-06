# honk for LuCI

适用于 OpenWrt / ImmortalWrt 25.12，包含 Honk 代理核心以及服务、配置、系统日志 LuCI 页面。

界面使用 LuCI 原生表单、页签和控件，布局与样式由当前主题提供，不包含独立 CSS 或额外的前端框架。Honk 配置文件和服务操作通过 RPC 处理。

软件包内置 [honk 官方 Release](https://github.com/daeuniverse/honk/releases) 的静态 musl full 核心，包括 eBPF 和 doona 界面，核心随 APK 升级。运行需要 root、Linux 6.12+、内核 BTF 和 cgroup v2；依赖见 [Makefile](Makefile)。内核未自带 BTF 时，需另行准备与内核匹配的 BTF 文件。

## 使用

1. 下载与设备 `apk --print-arch` 匹配的 APK，安装后重新登录 LuCI，进入 **服务 → honk**。首次安装不会启动服务或启用开机启动。
2. 编辑 `/etc/honk/config.dae`，按实际环境设置接口、订阅、节点和路由。配置示例见 [config.dae](root/etc/honk/config.dae)。z
3. 使用 Geo 规则时，首次启动前执行下方两条 curl 命令下载数据。
4. 保存配置，然后打开 **运行服务**。**开机启动**单独设置。

服务运行时保存新配置会发送热重载请求，停止时保持停止；未修改配置不会触发重载。请求成功不代表核心已接受新配置，请查看系统日志确认。下载来源、数据目录等需要重启才能生效的设置，修改后需手动停止再启动服务。配置路径变化时，`/etc/init.d/honk reload` 由 procd 替换服务实例。编辑器仅管理主配置文件，上限为 64 KiB，不使用 `--store db`。

核心路径为 `/usr/bin/honk-core`，在服务页显示版本；在线安装、更新和回退已移除。APK 升级会替换核心，并重启已启用开机启动的服务。首次安装和升级未启用开机启动的服务保持关闭。软件包与其他提供同名服务的 `honk` 包冲突，不能同时安装；运行中的 dae 也需先停止。

## Geo 数据

默认配置使用：

```dae
global {
    data_dir: '/etc/honk/data'
}
```

Geo 文件保存为 `/etc/honk/data/geosite.dat` 和 `/etc/honk/data/geoip.dat`，状态数据库位于 `/etc/honk/data/state/honk.db`。核心按配置中的 `data_dir` 查找文件。自行修改 `data_dir` 时需同步调整下方下载路径。

首次使用时，通过 SSH 在路由器上执行：

```sh
mkdir -p /etc/honk/data
curl -fL --retry 3 -o /etc/honk/data/geosite.dat 'https://gh-proxy.com/https://github.com/lauyv/rdat/raw/rel/geosite.dat'
curl -fL --retry 3 -o /etc/honk/data/geoip.dat 'https://gh-proxy.com/https://github.com/lauyv/cnip/raw/rel/chnroutes.dat'
```

确认两条命令均成功后再启动服务。仅设置 `assets.geodata` 下载来源不会补齐缺失文件；首次必须手动下载。

后续更新由 Honk 核心管理，示例配置已设置 `assets.geodata` 来源与直连下载路由。Native API 开启、状态数据库可用且允许配置写入并配置凭据时，核心默认每 24 小时检查已加载资源的更新，可通过原生面板调整设置或立即更新。启动不会立即下载；首次检查至少等待 5 分钟，再加最多 60 分钟随机延迟。

sysupgrade 保留整个 `/etc/honk/` 目录，包括配置、Geo 文件和状态数据库。

## 自动发布

GitHub Actions 的 **Release** 工作流每天 UTC 01:17（北京时间 09:17）检查上游最新发布；GitHub 定时任务可能延迟。筛选版本标签，包含 alpha/beta/rc，排除 Debug 构建。核心版本已发布到本仓库时跳过；否则下载官方静态 musl full 核心，校验 GitHub API 摘要、`SHA256SUMS`、ELF 架构和静态链接属性，再构建、发布 APK。手动运行工作流也会自动选择最新上游版本，无需填写参数。

发布标签跟随核心标签，预发布标记跟随上游。APK 版本按 OpenWrt 规则转换，如 `v0.1.0-beta.4` → `0.1.0_beta4-r1`；修订号取自 Makefile 的 `PKG_RELEASE`。相同核心版本不会重复发布；需要重新打包时，删除该版本的本仓库 Release 和标签后手动运行。发布说明包含自上次发布以来的完整 commit message 和上游版本链接。

每次发布包含五种 OpenWrt 架构的 APK：`aarch64_generic`、`aarch64_cortex-a53`、`aarch64_cortex-a72`、`aarch64_cortex-a76`、`x86_64`。四种 ARM64 包使用相同的通用 ARM64 静态核心，但 APK 架构元数据分别匹配设备。软件包不再是 `noarch`。

```sh
apk add --allow-untrusted /tmp/luci-app-honk-0.1.0_beta4-r1-x86_64.apk
```

## 本地构建

在 Linux 上准备 Bash、jq、tar、readelf、curl、Meson、Ninja、GCC、OpenSSL/zlib 开发文件及 fakeroot。先下载并校验核心，再打包：

```sh
bash .github/scripts/prepare-core.sh v0.1.0-beta.4 x86_64-unknown-linux-musl build/core
TOOLS_DIR="$PWD/build/tools" bash .github/scripts/prepare-tools.sh
RELEASE_TAG=v0.1.0-beta.4 OPENWRT_ARCH=x86_64 HONK_CORE_DIR="$PWD/build/core" TOOLS_DIR="$PWD/build/tools" bash .github/scripts/build-apk.sh
```

准备工具会下载并编译固定版本的 APK Tools v3。准备好的核心目录还包含许可证、核心与界面源码归档；发布 APK 时需一并提供对应源码。

使用 OpenWrt SDK 或固件源码树时，先用相同命令准备目标核心目录，再将仓库放入 `package/luci-app-honk`，启用 LuCI feed，选择软件包并编译：

```sh
make menuconfig
make package/luci-app-honk/compile HONK_CORE_DIR=/absolute/path/to/prepared/core V=s
```

ARM64 使用 `aarch64-unknown-linux-musl`，核心目录必须与 SDK 的目标架构一致。构建时要求主机安装 Bash、jq、tar、readelf。实际安装和运行需在设备上验证。

## 许可证

LuCI 管理界面采用 [MIT](LICENSE)；内置 Honk 和 doona 使用其上游许可证。APK 携带核心归档中的许可证与第三方声明，Release 同时提供匹配的 Honk 和 doona 源码归档以及 `SHA256SUMS`。
