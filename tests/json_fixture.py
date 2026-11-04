"""Host-side JSON selection shim for testing jshn call sites without OpenWrt."""
import json
import os
import re
from pathlib import Path
import shlex
import sys


def assignment(name, value):
    print(name + '=' + shlex.quote(str(value)))


def current():
    value = json.loads(Path(os.environ['JSON_FIXTURE_FILE']).read_text())
    for key in os.environ.get('JSON_FIXTURE_PATH', '').split('/'):
        if key:
            value = value[int(key) - 1] if isinstance(value, list) else value[key]
    return value


def main():
    mode = sys.argv[1]
    if mode == 'filter':
        args = sys.argv[2:]
        value = json.loads(Path(args[args.index('-i') + 1]).read_text())
        if '-t' in args:
            print('array' if isinstance(value, list) else 'object')
            return
        pattern = args[args.index('-e') + 1]
        if pattern == '@[@.draft=false].assets[*].name':
            for release in value:
                if release.get('draft') is False:
                    for asset in release.get('assets', []):
                        print(asset['name'])
        elif pattern in ('@.tag_name', '@.draft'):
            item = value.get(pattern[2:])
            print(str(item).lower() if isinstance(item, bool) else item)
        else:
            match = re.fullmatch(r'@\.assets\[@\.name="([^"]+)"\]\.(\w+)', pattern)
            if not match:
                raise ValueError(pattern)
            name, field = match.groups()
            for asset in value['assets']:
                if asset['name'] == name and asset.get(field) is not None:
                    print(asset[field])
    elif mode == '-R':
        json.loads(Path(sys.argv[2]).read_text())
        assignment('JSON_FIXTURE_FILE', sys.argv[2])
        assignment('JSON_FIXTURE_PATH', '')
    elif mode == 'select':
        path = os.environ.get('JSON_FIXTURE_PATH', '')
        key = sys.argv[2]
        if key == '..':
            path = path.rsplit('/', 1)[0] if '/' in path else ''
        else:
            value = current()
            selected = value[int(key) - 1] if isinstance(value, list) else value[key]
            if not isinstance(selected, (dict, list)):
                raise ValueError('Not a container')
            path = path + '/' + key
        assignment('JSON_FIXTURE_PATH', path)
    elif mode == 'keys':
        value = current()
        keys = range(1, len(value) + 1) if isinstance(value, list) else value.keys()
        assignment(sys.argv[2], ' '.join(str(key) for key in keys))
    elif mode == 'get':
        value = current().get(sys.argv[3], '')
        if isinstance(value, bool):
            value = int(value)
        if value is None:
            value = ''
        assignment(sys.argv[2], value)
    elif mode == 'dump':
        print(json.dumps({'versions': os.environ.get('JSON_VERSIONS', '').split()}))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, IndexError, OSError):
        sys.exit(1)
