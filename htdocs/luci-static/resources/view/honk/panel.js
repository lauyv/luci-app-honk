'use strict';
'require view';
'require rpc';
'require poll';
'require ui';

const MAX_SIZE = 65536;

function method(name, params) {
  return rpc.declare({
    object: 'luci.honk',
    method: name,
    params: params || [],
    expect: { '': {} },
  });
}

const api = {
  status: method('status'),
  read: method('read'),
  logs: method('logs'),
  save: method('save', ['content', 'revision']),
  check: method('check', ['content']),
  action: method('action', ['name', 'revision']),
  autostart: method('autostart', ['enabled']),
  geo: method('geo', ['geosite_url', 'geoip_url']),
  preferences: method('preferences', ['proxy']),
};

const messages = {
  apply_failed: '配置已保存，但服务未能稳定启动，请检查日志并修改配置',
  operation_interrupted: '操作已中断，请检查配置和服务状态',
  config_path_invalid: '配置文件必须位于 /etc/honk 内，且以 .dae 结尾',
  config_not_regular: '配置路径不是普通文件',
  config_symlink: '不支持符号链接配置文件',
  service_missing: '缺少 honk 可执行文件或启动脚本',
  config_missing: '没有已保存的配置',
  config_too_large: '配置大小超过 64 KiB',
  check_failed: '配置校验失败（退出码 %s）',
  check_prepare_failed: '无法准备临时校验文件',
  operation_running: '正在执行：%s',
  check_passed: '配置文件通过 honk 校验',
  config_applied: '配置已应用，服务 PID 保持稳定。未测试网络连通性。',
  start_failed: '服务未能稳定启动，请检查日志',
  service_running: '服务正在运行',
  stop_failed: '服务未能停止',
  service_stopped: '服务已停止',
  action_unknown: '未知操作',
  directories_failed: '无法初始化面板目录',
  flock_missing: '固件缺少 flock 命令，请启用 BusyBox flock 或安装 flock 软件包',
  logs_failed: '无法读取系统日志（logread 失败或超时）',
  request_invalid: '请求无效',
  content_invalid: '配置内容必须是字符串',
  operation_busy: '另一项操作正在执行',
  config_save_failed: '无法保存配置文件',
  core_missing: '尚未安装核心，请在核心管理中安装',
  architecture_unsupported: '目前支持 ARM64 和 x86_64 设备',
  download_failed: '下载失败，请检查网络、代理设置或 GitHub API 限制',
  download_too_large: '下载文件超过允许大小',
  releases_invalid: 'GitHub 发布信息无效',
  releases_updated: '官方版本列表已更新',
  version_invalid: '请选择有效的官方版本',
  asset_missing: '该版本缺少对应架构的 full 核心或校验文件',
  digest_missing: '官方 API 未提供可靠的 SHA-256 摘要，未安装',
  digest_mismatch: '摘要校验失败，当前核心保持不变',
  archive_invalid: '压缩包结构无效，当前核心保持不变',
  binary_invalid: '核心不是适合本机的可执行程序',
  version_mismatch: '核心版本与选择的版本不一致',
  core_path_unsafe: '核心目录必须为 root 所有，且不能使用符号链接',
  core_write_failed: '无法写入核心目录，请检查剩余空间和权限',
  core_installed: '核心安装完成，保持原运行状态',
  core_rolled_back: '已回退到上一核心，保持原运行状态',
  core_restored: '新核心启动失败，已恢复并启动旧核心',
  core_recovery_failed: '核心恢复未完成，请查看日志；上一核心仍保留在核心目录',
  rollback_missing: '没有可回退的核心',
  geo_url_invalid: 'Geo 下载地址必须为有效的 HTTPS 地址',
  geo_invalid: 'Geo 文件为空、过大或基础格式检查失败',
  geo_path_invalid: '自定义 Geo 数据目录无效',
  geo_empty: '请至少填写一个 Geo 下载地址',
  geo_write_failed: '无法保存 Geo 数据或设置，请检查空间和权限',
  geo_settings_changed: '下载期间设置或数据发生变化，请刷新后重试',
  geo_restart_failed: 'Geo 设置已保存，但服务未能启动',
  geo_restored: '新 Geo 数据启动失败，已恢复旧文件和设置并启动服务',
  geo_recovery_failed: 'Geo 数据恢复未完成，请查看日志及详情中的备份目录',
  geo_applied: 'Geo 数据已更新，保持原运行状态',
  preferences_invalid: '代理前缀应留空或填写有效的 HTTPS 地址',
  preferences_saved: '核心管理设置已保存',
  preferences_failed: '无法保存核心管理设置',
  config_saved: '配置文件已保存；服务保持停止',
  config_unchanged: '配置没有变化；服务未重启',
  config_changed: '配置文件已改变，请重新加载后再保存',
  operation_queued: '操作已加入队列',
  enabled_invalid: 'enabled 必须是布尔值',
  autostart_updated: '开机启动设置已更新',
  autostart_failed: '无法更改开机启动设置',
  method_unknown: '未知方法',
  service_status_failed: '无法确认服务进程状态，操作已中止',
};

const actions = {
  validate: '校验',
  save: '保存配置',
  start: '启动',
  stop: '停止',
  check_updates: '检查版本',
  install: '安装核心',
  rollback: '回退核心',
  geo: '应用 Geo 数据',
};

function message(result) {
  const value = result.code === 'operation_running' ? actions[result.argument] : result.argument;
  return Object.prototype.hasOwnProperty.call(messages, result.code)
    ? messages[result.code].replace('%s', () => (value == null ? '' : String(value)))
    : result.message || '后端返回无效响应';
}

function checked(result) {
  if (!result || !result.ok) throw new Error(result ? message(result) : '后端返回无效响应');
  return result;
}

function field(title, node) {
  return E('div', { class: 'cbi-value' }, [
    E('div', { class: 'cbi-value-title' }, title),
    E('div', { class: 'cbi-value-field' }, node),
  ]);
}

return view.extend({
  handleSaveApply: null,
  handleSave: null,
  handleReset: null,

  load() {
    return Promise.all([api.status().then(checked), api.read()]);
  },

  notify(text, error, details) {
    if (this.notification) this.notification.remove();
    const content = E('div', {}, [E('p', {}, text)]);
    if (details) content.appendChild(E('pre', { class: 'honk-output' }, details));
    this.notification = error
      ? ui.addNotification(null, content, 'error')
      : ui.addTimeLimitedNotification(null, content, 4500, 'info');
  },

  updateControls() {
    const busy = !!(this.localBusy || this.status.busy);
    this.buttons.forEach(({ node, write, config }) => {
      node.disabled = busy || (write && !this.writable) || (config && !this.loaded);
    });
    this.boot.disabled = busy || !this.writable;
    this.running.disabled = busy || !this.writable || !this.status.core_installed;
    if (this.releaseSelect) {
      const readonly = busy || !this.writable;
      this.releaseSelect.disabled = readonly;
      this.proxyPrefix.disabled = readonly;
      this.geositeUrl.disabled = readonly;
      this.geoipUrl.disabled = readonly;
      this.installButton.disabled = readonly || !this.status.target || !this.releaseSelect.value;
      this.rollbackButton.disabled = readonly || !this.status.rollback_available;
    }
    this.editor.readOnly = busy || !this.writable || !this.loaded;
  },

  async run(fn, write) {
    if (this.localBusy || this.status.busy || (write && !this.writable)) return;
    this.localBusy = true;
    this.updateControls();
    try {
      await fn();
    } catch (error) {
      this.notify(error.message, true);
    } finally {
      this.localBusy = false;
      try {
        await this.refresh();
      } catch (error) {
        this.notify(error.message, true);
      }
      this.updateControls();
    }
  },

  button(label, fn, style, write = true, config = false) {
    const node = E(
      'button',
      {
        type: 'button',
        class: 'cbi-button cbi-button-' + (style || 'action'),
        click: () => this.run(fn, write),
      },
      label,
    );
    this.buttons.push({ node, write, config });
    return node;
  },

  updateDirty() {
    this.dirty.textContent = !this.loaded
      ? '配置读取失败，请修复后重载。'
      : this.status.revision && this.status.revision !== this.revision
        ? messages.config_changed
        : this.editor.value !== this.savedText
          ? '有未保存的修改。'
          : '编辑器内容与配置文件一致。';
  },

  setConfig(result) {
    checked(result);
    this.savedText = result.content || '';
    this.editor.value = this.savedText;
    this.revision = result.revision;
    this.loaded = true;
    this.updateDirty();
  },

  content() {
    if (!this.loaded) throw new Error('请先重载配置');
    if (new Blob([this.editor.value]).size > MAX_SIZE) throw new Error(messages.config_too_large);
    return this.editor.value;
  },

  async queue(name, revision) {
    checked(await api.action(name, revision || ''));
    this.status.busy = true;
    this.lastJob = null;
  },

  async saveCorePreferences() {
    checked(await api.preferences(this.proxyPrefix.value.trim()));
  },

  async applyGeo() {
    if (this.status.running && !window.confirm('Geo 数据下载成功后会重启正在运行的服务，继续？')) return;
    checked(await api.geo(this.geositeUrl.value.trim(), this.geoipUrl.value.trim()));
    this.status.busy = true;
    this.lastJob = null;
  },

  updateCore(status) {
    this.coreVersion.textContent = status.version || '尚未安装';
    this.coreTarget.textContent = status.target ? status.target + '-full' : '不支持当前设备架构';
    if (!this.preferencesLoaded) {
      this.proxyPrefix.value = status.proxy_prefix || '';
      this.geositeUrl.value = status.geosite_url || '';
      this.geoipUrl.value = status.geoip_url || '';
      this.preferencesLoaded = true;
    }
    const cached = status.releases || '';
    if (cached !== this.releaseCache) {
      this.releaseCache = cached;
      const selected = this.releaseSelect.value;
      let versions = [];
      try { versions = JSON.parse(cached).versions || []; } catch { /* No cache before the first check. */ }
      this.releaseSelect.replaceChildren(...(versions.length
        ? versions.map(tag => E('option', { value: tag }, tag))
        : [E('option', { value: '' }, '请先检查版本')]));
      if (versions.includes(selected)) this.releaseSelect.value = selected;
      this.releaseHint.textContent = versions.length
        ? '列出官方最近 10 条发布中适合本机的 full 构建，包含预发布版。'
        : '';
    }
  },

  renderCore() {
    this.coreVersion = E('span');
    this.coreTarget = E('code');
    this.releaseHint = E('p', { class: 'cbi-section-descr' });
    this.releaseSelect = E('select', { class: 'cbi-input-select', 'aria-label': '核心版本' });
    this.proxyPrefix = E('input', {
      class: 'cbi-input-text', type: 'url', placeholder: 'https://gh-proxy.com', 'aria-label': '代理前缀',
    });
    const check = this.button('检查版本', () => this.queue('check_updates'));
    const preferences = this.button('保存核心设置', async () => {
      await this.saveCorePreferences();
      this.notify(messages.preferences_saved);
    });
    this.installButton = this.button('安装／更新', async () => {
      const tag = this.releaseSelect.value;
      if (!tag) throw new Error('请先检查并选择核心版本');
      if (!window.confirm('安装 ' + tag + '？运行中的服务会短暂停止；启动失败时尝试恢复旧核心。')) return;
      await this.saveCorePreferences();
      await this.queue('install', tag);
    }, 'apply');
    this.rollbackButton = this.button('回退上一版本', async () => {
      if (!window.confirm('回退到上一次保留的核心？运行中的服务会短暂停止。')) return;
      await this.queue('rollback');
    });
    this.releaseSelect.addEventListener('change', () => this.updateControls());
    return E('div', { 'data-tab': 'core', 'data-tab-title': '核心管理' }, [
      field('当前版本', this.coreVersion),
      field('下载构建', this.coreTarget),
      field('可用版本', [E('div', { class: 'honk-actions' }, [this.releaseSelect, check]), this.releaseHint]),
      field('代理前缀', [this.proxyPrefix,
        E('div', { class: 'cbi-value-description' }, '留空时直连 GitHub；填写 https://gh-proxy.com 或自定义 HTTPS 前缀时用于核心文件下载，不代理 GitHub API。')]),
      E('div', { class: 'cbi-page-actions honk-actions' }, [preferences, this.installButton, this.rollbackButton]),
      E('p', { class: 'cbi-section-descr' }, '下载后核对官方摘要、架构、版本和现有配置。更新保持原运行状态；核心不由 APK 管理。'),
    ]);
  },

  renderGeo() {
    this.geositeUrl = E('input', { class: 'cbi-input-text honk-geo-url', type: 'url', maxlength: 2048,
      placeholder: 'https://example.com/geosite.dat', 'aria-label': 'geosite.dat 下载地址' });
    this.geoipUrl = E('input', { class: 'cbi-input-text honk-geo-url', type: 'url', maxlength: 2048,
      placeholder: 'https://example.com/geoip.dat', 'aria-label': 'geoip.dat 下载地址' });
    const geoApply = this.button('更新 Geo 数据', () => this.applyGeo(), 'apply');
    return E('div', { 'data-tab': 'geo', 'data-tab-title': 'Geo 数据' }, [
      field('geosite.dat 地址', this.geositeUrl),
      field('geoip.dat 地址', this.geoipUrl),
      E('p', { class: 'cbi-section-descr' }, '文件固定保存为 /etc/honk/geosite.dat 和 /etc/honk/geoip.dat，请在配置中设置 data_dir: \'/etc/honk\'。留空项保留已有文件。按填写的 URL 直接下载；需要加速时，请在 URL 中填写完整代理地址。'),
      E('p', { class: 'cbi-section-descr' }, '点击“更新 Geo 数据”将使用当前填写的地址重新下载。运行中的服务会在下载成功后重启，停止的服务保持停止。'),
      E('div', { class: 'cbi-page-actions honk-actions' }, [geoApply]),
    ]);
  },

  async save() {
    const content = this.content();
    const result = checked(await api.save(content, this.revision));
    this.pendingSave = { id: result.id, content };
    this.status.busy = true;
    this.lastJob = null;
  },

  updateStatus(status) {
    this.status = status;
    this.runtime.textContent = status.running ? '运行中 · PID ' + status.pid : '已停止';
    this.version.textContent = status.version || '尚未安装核心，请前往“核心管理”安装';
    this.environment.textContent = status.environment || '';
    this.updateCore(status);
    this.path.textContent = status.config || '未配置';
    if (!this.localBusy) {
      this.boot.checked = !!status.autostart;
      this.running.checked = !!status.running;
    }
    if (this.pendingSave && status.job) {
      try {
        const job = JSON.parse(status.job);
        if (job.id === this.pendingSave.id && (job.state === 'success' || job.state === 'error')) {
          if (job.revision) {
            this.savedText = this.pendingSave.content;
            this.revision = job.revision;
          }
          this.pendingSave = null;
        }
      } catch { /* Malformed job data is reported below. */ }
    }
    this.problem.textContent = status.error_code ? message({ code: status.error_code }) : '';
    this.problem.hidden = !this.problem.textContent;
    this.progress.textContent = status.busy ? '后台操作进行中，请稍候…' : '';
    if (status.job && status.job !== this.lastJob) {
      this.lastJob = status.job;
      try {
        const job = JSON.parse(status.job);
        if (job.state === 'error' || job.state === 'success')
          this.notify(message(job), job.state === 'error', job.details);
        else if (status.busy && job.state === 'running')
          this.progress.textContent = message(job) + (job.details ? ' · ' + job.details : '');
      } catch {
        this.notify('无法解析后台操作状态', true);
      }
    }
    this.updateDirty();
    this.updateControls();
  },

  async refresh() {
    this.updateStatus(checked(await api.status()));
  },

  async refreshLogs() {
    if (this.loadingLogs) return;
    this.loadingLogs = true;
    try {
      const result = checked(await api.logs());
      this.logHint.textContent = '';
      // oxlint-disable-next-line no-control-regex -- Strip ANSI color codes from system logs.
      const ansi = /(?:\x1b\[|\x9b)[0-9;:]*m/g;
      this.logs.value = (result.content || '').replace(ansi, '') || '暂无 honk 系统日志。';
      this.logUpdated.textContent = '更新于 ' + new Date().toLocaleTimeString('zh-CN');
    } catch (error) {
      this.logHint.textContent = '日志刷新失败：' + error.message;
    } finally {
      this.loadingLogs = false;
    }
  },

  render(data) {
    this.writable = L.hasViewPermission() === true;
    this.status = data[0];
    this.buttons = [];
    this.loaded = false;
    this.localBusy = false;
    this.runtime = E('strong');
    this.version = E('span');
    this.environment = E('span');
    this.path = E('code');
    this.problem = E('p', { class: 'cbi-section-descr', role: 'alert', hidden: true });
    this.progress = E('p', { role: 'status', 'aria-live': 'polite' });
    this.dirty = E('div', { class: 'cbi-section-descr', 'aria-live': 'polite' });
    this.editor = E('textarea', {
      class: 'cbi-input-textarea',
      rows: 24,
      spellcheck: 'false',
      'aria-label': 'honk .dae 配置',
      input: () => this.updateDirty(),
    });
    const checkbox = new ui.Checkbox('0', { id: 'honk-autostart' }).render();
    this.boot = checkbox.querySelector('input[type="checkbox"]');
    this.boot.setAttribute('aria-label', '开机启动');
    this.boot.addEventListener('change', () => {
      const enabled = this.boot.checked;
      this.run(async () => {
        checked(await api.autostart(enabled));
        this.notify(messages.autostart_updated);
      }, true);
    });
    const runningCheckbox = new ui.Checkbox('0', { id: 'honk-running' }).render();
    this.running = runningCheckbox.querySelector('input[type="checkbox"]');
    this.running.setAttribute('aria-label', '运行服务');
    this.running.addEventListener('change', () => {
      const enabled = this.running.checked;
      this.run(() => this.queue(enabled ? 'start' : 'stop'), true);
    });
    const overview = E('div', { 'data-tab': 'overview', 'data-tab-title': '服务' }, [
      field('运行状态', this.runtime),
      field('开机启动', checkbox),
      field('运行服务', runningCheckbox),
      field('核心版本', this.version),
      field('运行环境', this.environment),
      field('配置文件', this.path),
    ]);
    const config = E('div', { 'data-tab': 'config', 'data-tab-title': '配置' }, [
      this.dirty,
      this.editor,
      E('p', { class: 'cbi-section-descr' }, '保存前校验；运行中的服务会重启，已停止的服务保持停止。'),
      E('div', { class: 'cbi-page-actions honk-actions' }, [
        this.button(
          '重载配置',
          async () => {
            if (this.loaded && this.editor.value !== this.savedText && !window.confirm('放弃未保存的修改并重载配置？'))
              return;
            this.setConfig(await api.read());
          },
          'reset',
          false,
        ),
        this.button(
          '校验',
          async () => {
            checked(await api.check(this.content()));
            this.status.busy = true;
            this.lastJob = null;
          },
          'action',
          true,
          true,
        ),
        this.button('保存', () => this.save(), 'apply', true, true),
      ]),
    ]);
    this.logHint = E('div', { class: 'cbi-section-descr', role: 'status' });
    this.logUpdated = E('div', { class: 'cbi-section-descr' });
    this.logs = E('textarea', {
      class: 'cbi-input-textarea',
      rows: 20,
      readonly: '',
      'aria-label': 'honk 系统日志',
    });
    const logs = E('div', { 'data-tab': 'logs', 'data-tab-title': '系统日志' }, [
      this.logHint,
      this.logUpdated,
      this.logs,
    ]);
    logs.addEventListener('cbi-tab-active', () => this.refreshLogs());
    const core = this.renderCore();
    const geo = this.renderGeo();
    const panes = E('div', {}, [overview, config, core, geo, logs]);
    const root = E('div', { class: 'cbi-map', id: 'honk-panel' }, [
      E('link', { rel: 'stylesheet', href: L.resource('view/honk/panel.css') }),
      E('h2', {}, 'honk'),
      E('p', { class: 'cbi-map-descr' }, this.writable ? '配置与服务管理' : '当前账号仅有查看权限。'),
      this.problem,
      this.progress,
      E('div', { class: 'cbi-section' }, [panes]),
    ]);
    ui.tabs.initTabGroup(panes.childNodes);
    try {
      this.setConfig(data[1]);
    } catch (error) {
      this.notify(error.message, true);
    }
    // 已完成的成功任务不在重新进入页面时重复提示。
    try {
      if (this.status.job && JSON.parse(this.status.job).state === 'success') this.lastJob = this.status.job;
    } catch {
      /* updateStatus reports malformed task data. */
    }
    this.updateStatus(this.status);
    poll.add(async () => {
      try {
        await this.refresh();
      } catch (error) {
        this.problem.textContent = '状态刷新失败：' + error.message;
        this.problem.hidden = false;
      }
      if (logs.getAttribute('data-tab-active') === 'true') await this.refreshLogs();
    }, 5);
    return root;
  },
});
