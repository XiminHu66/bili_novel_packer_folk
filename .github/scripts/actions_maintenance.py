"""Repository-scoped, bounded artifact cleanup. Never deletes releases or workflow runs."""
import argparse
import datetime as dt
import json
import os
import urllib.error
import urllib.request
from collections import defaultdict

INSTALLERS = {
    'anime-player': {'Anime1Player-Windows', 'Anime1Player-Windows-EXE', 'Anime1Player-Portable'},
    'video-streamer': {'VideoStreamer-Windows'},
}
REQUIRED = {
    'anime-player': {'Anime1Player.exe', 'Anime1Player-Portable.zip', 'SHA256SUMS.txt'},
    'video-streamer': {'VideoStreamer-App.zip', 'VideoStreamer-Portable.zip', 'update.json',
                       'VideoStreamer-App.zip.sha256', 'VideoStreamer-Portable.zip.sha256'},
}
UTC = dt.timezone.utc
def stamp(value): return dt.datetime.fromisoformat(value.replace('Z', '+00:00'))

def candidates(artifacts, repo, now, release_verified=False, current_run=None, completed=None):
    """Return only named, completed-run files; keep fresh diagnostic evidence."""
    completed = completed or set()
    groups = defaultdict(list)
    for a in artifacts:
        if not a.get('expired'):
            groups[a['name']].append(a)
    selected = []
    for name, group in groups.items():
        group.sort(key=lambda a: (a['created_at'], a['id']), reverse=True)
        for index, a in enumerate(group):
            run_id = a.get('workflow_run', {}).get('id')
            if not run_id or run_id == current_run or run_id not in completed:
                continue
            age = now - stamp(a['created_at'])
            if age.total_seconds() < 0:
                continue
            installer = name in INSTALLERS.get(repo, set())
            fixture = name in {'tool-frontends-48', 'bilipack-arm64-fixture'}
            diagnostic = any(s in name.lower() for s in ('screenshot', 'browser-review', 'layout', 'ui-proof', 'lan-proof', 'validation', 'verification', 'probe'))
            firmware = name in {'pocket-nexus-firmware', 'toy-dg-release', 'toy-dg-launcher', 'toy-dg-web', 'toy-dg-windows'}
            if installer and release_verified:
                selected.append(a)
            elif fixture and age > dt.timedelta(hours=1):
                selected.append(a)
            elif diagnostic and index >= 2 and age > dt.timedelta(days=3):
                selected.append(a)
            elif firmware and index >= 2 and age > dt.timedelta(days=7):
                selected.append(a)
    return selected

def main():
    ap = argparse.ArgumentParser(); ap.add_argument('--apply', action='store_true')
    ap.add_argument('--run-id', type=int, help='Only clean this completed release/fixture run')
    args = ap.parse_args()
    repo_full = os.environ['GITHUB_REPOSITORY']
    if not repo_full.startswith('XiminHu66/') or repo_full.count('/') != 1:
        raise SystemExit('Unexpected repository scope')
    repo = repo_full.split('/')[1]
    token = os.environ['GH_TOKEN']
    base = 'https://api.github.com/repos/' + repo_full
    def api(path, method='GET'):
        req = urllib.request.Request(base + path, method=method, headers={
            'Authorization': 'Bearer ' + token, 'Accept': 'application/vnd.github+json',
            'X-GitHub-Api-Version': '2022-11-28', 'User-Agent': 'PT-Actions-Maintenance/1'})
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                return json.load(r) if r.status != 204 else None
        except urllib.error.HTTPError as e:
            raise RuntimeError(f'GitHub {method} {path}: HTTP {e.code}') from None
    def paged(path, key):
        values = []
        for page in range(1, 101):
            d = api(f'{path}{"&" if "?" in path else "?"}per_page=100&page={page}')
            batch = d[key] if key else d
            values.extend(batch)
            if len(batch) < 100: return values
        raise RuntimeError('Pagination bound exceeded; no deletion performed')
    artifacts = paged('/actions/artifacts', 'artifacts')
    verified = False
    if repo in REQUIRED:
        release = api('/releases/latest')
        names = {a['name'] for a in release['assets'] if a.get('size', 0) > 0}
        verified = not release.get('draft') and not release.get('prerelease') and REQUIRED[repo] <= names
        if not verified: raise RuntimeError('Latest published release is incomplete; cleanup refused')
        print('Protected published release:', release['tag_name'], 'assets:', len(names))
    eligible = [a for a in artifacts if not args.run_id or a.get('workflow_run', {}).get('id') == args.run_id]
    completed = set()
    # Query only runs that may contain a cleanup target; never touch active handoffs.
    names = INSTALLERS.get(repo, set()) | {'tool-frontends-48', 'bilipack-arm64-fixture'}
    for run_id in sorted({a.get('workflow_run', {}).get('id') for a in eligible if not a.get('expired') and a.get('workflow_run', {}).get('id')}):
        run = api('/actions/runs/' + str(run_id))
        if run['status'] == 'completed': completed.add(run_id)
    plan = candidates(eligible, repo, dt.datetime.now(UTC), verified,
                      int(os.environ.get('GITHUB_RUN_ID', '0')), completed)
    removed = 0
    for a in plan:
        print(('DELETE' if args.apply else 'WOULD DELETE'), a['id'], a['name'], a['size_in_bytes'])
        if args.apply: api('/actions/artifacts/' + str(a['id']), 'DELETE')
        removed += a['size_in_bytes']
    remaining = paged('/actions/artifacts', 'artifacts') if args.apply else artifacts
    report = {'repository': repo_full, 'apply': args.apply, 'deleted_count': len(plan) if args.apply else 0,
              'deleted_bytes': removed if args.apply else 0, 'remaining_count': sum(not a.get('expired') for a in remaining),
              'remaining_bytes': sum(a['size_in_bytes'] for a in remaining if not a.get('expired'))}
    print('MAINTENANCE_RESULT ' + json.dumps(report))
    if os.environ.get('GITHUB_STEP_SUMMARY'):
        with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as f:
            f.write('## Artifact cleanup\n\n```json\n' + json.dumps(report, indent=2) + '\n```\n')

if __name__ == '__main__': main()
