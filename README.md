# honk for LuCI

适用于 OpenWrt / ImmortalWrt 25.12 的 honk 管理界面，提供服务、配置、核心管理、Geo 数据和系统日志页面。

应用不包含核心，从 [honk 官方 Release](https://github.com/daeuniverse/honk/releases) 下载静态 musl full 构建，支持 ARM64 和 x86_64。运行需要 root、Linux 6.12+、BTF 和 cgroup v2；软件包依赖见 [Makefile](Makefile)。

## 使用

1. 安装应用后重新登录 LuCI，进入 **服务 → honk**。首次安装不会启动服务或启用开机启动。
2. 在 **核心管理** 检查版本并安装核心。版本列表筛选官方最近 10 条发布中适合本机的 full 构建，包含预发布版。
3. 在 **配置** 编辑 `/etc/honk/config.dae`，按实际环境设置接口、订阅、节点和路由。配置示例见 [config.dae](root/etc/honk/config.dae)。
4. 使用 Geo 规则时，在 **Geo 数据** 下载所需文件，也可通过 SSH 手动放入数据目录。
5. 校验并保存配置，然后打开 **运行服务**。**开机启动**单独设置。

服务运行时保存新配置会重启应用，停止时保持停止；未修改配置不会触发重启。编辑器只修改主配置文件，`include` 引用由核心一并校验。配置上限为 64 KiB。

beta.5 的配置校验通过只读 `delay` 子命令完成，使用随机不存在的节点名判断校验结果，不启动引擎或探测远程节点。校验通过不代表运行环境、Geo 规则或网络连通性正常。

## 核心管理

代理前缀默认为 `https://gh-proxy.com`，留空则直连 GitHub。前缀仅用于核心压缩包和 `SHA256SUMS`，GitHub API 始终直连。

下载后核对官方 API 摘要、`SHA256SUMS`、架构和版本。更新运行中的服务前先校验现有配置；更新及回退保持原运行状态，新核心启动失败时尝试恢复旧核心。

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
    data_dir: '/etc/honk'
}
```

Geo 下载固定保存为 `/etc/honk/geosite.dat` 和 `/etc/honk/geoip.dat`，数据库位于 `/etc/honk/state/honk.db`。核心按配置中的 `data_dir` 查找文件，启动脚本不设置额外的 Geo 环境变量。自行修改 `data_dir` 时需同步调整文件位置。

默认下载地址：

```text
geosite.dat: https://gh-proxy.com/https://github.com/lauyv/rdat/raw/rel/geosite.dat
geoip.dat:   https://gh-proxy.com/https://github.com/lauyv/cnip/raw/rel/chnroutes.dat
```

Geo 按填写的完整 URL 直接下载。点击 **更新 Geo 数据**使用当前填写的地址重新下载。空地址项保留已有文件，至少填写一个地址。

文件上限为 64 MiB，下载并通过基础格式检查后才替换；完整数据有效性由核心加载时确认。服务运行时更新成功后重启，启动失败尝试恢复旧文件。恢复失败会保留备份并在任务详情显示路径。断电或强制终止更新可能需要手动恢复。

核心与 `/etc/honk/` 已加入 sysupgrade 保留清单，卸载应用不主动删除用户数据。

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

## 开发验证

```sh
python3 -m unittest discover -s tests -p 'test_*.py' -v
node --check htdocs/luci-static/resources/view/honk/panel.js
python3 tests/preview/build.py
BROWSER_BIN=/path/to/chromium node tests/browser.mjs
```

直接打开 `build/preview.html` 后，版本查询会读取官方 GitHub API，并按选择的预览架构筛选 full 构建；安装和服务操作仍为模拟。浏览器自动测试使用固定的 API 响应，无需联网。主机测试不能替代设备上的实际安装和运行验证。

## 许可证

本应用采用 [MIT](LICENSE)。honk 及 doona 使用各自上游许可证，APK 不包含其二进制。
