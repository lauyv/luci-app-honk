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
  action: method('action', ['name']),
  autostart: method('autostart', ['enabled']),
};

const messages = {
  apply_failed: '配置已保存，但重载请求失败或服务运行异常，请检查日志',
  operation_interrupted: '操作已中断，请检查配置和服务状态',
  config_path_invalid: '配置文件必须位于 /etc/honk 内，且以 .dae 结尾',
  config_not_regular: '配置路径不是普通文件',
  config_symlink: '不支持符号链接配置文件',
  service_missing: '缺少 honk 可执行文件或启动脚本',
  config_missing: '没有已保存的配置',
  config_too_large: '配置大小超过 64 KiB',
  operation_running: '正在执行：%s',
  config_applied: '配置已保存并发送重载请求，请在日志中确认结果；部分设置需重启服务。',
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
  config_saved: '配置文件已保存；服务保持停止',
  config_unchanged: '配置没有变化；未发送重载请求',
  config_changed: '配置文件已改变，请重新加载后再保存',
  operation_queued: '操作已加入队列',
  enabled_invalid: 'enabled 必须是布尔值',
  autostart_updated: '开机启动设置已更新',
  autostart_failed: '无法更改开机启动设置',
  method_unknown: '未知方法',
  service_status_failed: '无法确认服务进程状态，操作已中止',
};

const actions = {
  save: '保存配置',
  start: '启动',
  stop: '停止',
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

  async queue(name) {
    checked(await api.action(name));
    this.status.busy = true;
    this.lastJob = null;
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
    this.version.textContent = status.version || '缺少核心，请重新安装软件包';
    this.environment.textContent = status.environment || '';
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
      E('p', { class: 'cbi-section-descr' }, '保存后向运行中的服务发送重载请求，已停止的服务保持停止。重载结果请查看日志；部分设置需手动重启服务。'),
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
    const panes = E('div', {}, [overview, config, logs]);
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
