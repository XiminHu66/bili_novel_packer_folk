"""Fail CI when workflows reintroduce unbounded storage or automatic player releases."""
from pathlib import Path
import json
import re
import sys
import yaml

class Loader(yaml.SafeLoader): pass
Loader.yaml_implicit_resolvers = {k: [(t, r) for t, r in v if t != 'tag:yaml.org,2002:bool'] for k, v in Loader.yaml_implicit_resolvers.items()}
Loader.add_implicit_resolver('tag:yaml.org,2002:bool', re.compile(r'^(?:true|false|True|False|TRUE|FALSE)$'), list('tTfF'))

def validate(root):
    errors = []
    config_path=root/'.github/actions-resource-policy.json'
    config=json.loads(config_path.read_text()) if config_path.exists() else {}
    for path in sorted((root / '.github/workflows').glob('*.y*ml')):
        d = yaml.load(path.read_text(), Loader=Loader)
        if not isinstance(d, dict): errors.append(f'{path.name}: invalid mapping'); continue
        if not d.get('concurrency'): errors.append(f'{path.name}: explicit concurrency required')
        on = d.get('on') or {}
        if config.get('source_mode')=='canonical-client' and 'schedule' in on:
            errors.append(f'{path.name}: canonical data clients must not schedule a duplicate scraper')
        if path.name == 'windows.yml' and (root/'version.py').exists() or path.name == 'windows.yml' and (root/'videolib').exists():
            push = on.get('push') or {}
            if 'branches' in push or not push.get('tags'):
                errors.append(f'{path.name}: full player build must be tag/manual only')
        for key, job in d.get('jobs', {}).items():
            if 'uses' in job: continue
            timeout = job.get('timeout-minutes')
            if not isinstance(timeout, int) or not 1 <= timeout <= 45:
                errors.append(f'{path.name}/{key}: timeout must be 1..45 minutes')
            for st in job.get('steps', []):
                use = st.get('uses', '')
                if 'actions/upload-artifact@' in use or 'actions/upload-pages-artifact@' in use:
                    w = st.get('with', {}); days = w.get('retention-days')
                    try: valid = 1 <= int(days) <= 7
                    except (TypeError, ValueError): valid = False
                    if not valid: errors.append(f'{path.name}/{key}: explicit retention-days 1..7 required')
                    if re.search(r'Anime1Player|VideoStreamer-Windows|fixture|tool-frontends', str(w.get('name',''))) and str(days) != '1':
                        errors.append(f'{path.name}/{key}: intermediate binaries must retain at most 1 day')
    return errors

if __name__ == '__main__':
    root = Path(sys.argv[1] if len(sys.argv)>1 else '.')
    errors = validate(root)
    for error in errors: print('ERROR:', error)
    if errors: raise SystemExit(1)
    print('PASS: all workflows have bounded runtime, storage and release triggers')
