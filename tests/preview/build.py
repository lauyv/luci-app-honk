"""Generate a standalone preview from the actual LuCI view."""
from pathlib import Path
import json

ROOT = Path(__file__).resolve().parents[2]


def literal(text):
    return json.dumps(text, ensure_ascii=False).replace('</script', '<\\/script')


def main():
    html = Path(__file__).with_name('template.html').read_text()
    html = html.replace('{{SOURCE}}', literal((ROOT / 'htdocs/luci-static/resources/view/honk/panel.js').read_text()))
    html = html.replace('{{CONFIG}}', literal((ROOT / 'root/etc/honk/config.dae').read_text()))
    html = html.replace('{{PANEL_CSS}}', (ROOT / 'htdocs/luci-static/resources/view/honk/panel.css').read_text())
    output = ROOT / 'build/preview.html'
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(html)
    print(output)


if __name__ == '__main__':
    main()
