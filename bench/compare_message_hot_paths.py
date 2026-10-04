#!/usr/bin/env python3
"""Compare frozen Rails sources with isolated fixtures and an existing Ruby image."""
import argparse
import json
import hashlib
import pathlib
import platform
import shutil
import statistics
import subprocess

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--baseline', type=pathlib.Path, required=True)
p.add_argument('--baseline-ref', help='Git revision used to create the baseline snapshot')
p.add_argument('--seed', type=pathlib.Path, required=True)
p.add_argument('--image', default='campfire-reference:app')
p.add_argument('--cpus', default='8-11')
p.add_argument('--rounds', type=int, default=4)
p.add_argument('--output', type=pathlib.Path, required=True)
a = p.parse_args()
if a.rounds < 2 or a.rounds % 2:
    p.error('--rounds must be positive and even for balanced AB/BA order')
root = pathlib.Path(__file__).resolve().parents[1]
work = root / 'tmp/rails-optimization/runtime'
a.output.mkdir(parents=True, exist_ok=True)
for name in ['tmp', 'log', 'assets']:
    (work / name).mkdir(parents=True, exist_ok=True)
if not any((work / 'assets').iterdir()):
    tar = subprocess.run(['docker', 'run', '--rm', '--entrypoint', '', a.image,
                          'tar', '-C', '/rails/public/assets', '-cf', '-', '.'], capture_output=True, check=True)
    subprocess.run(['tar', '-xf', '-', '-C', str(work / 'assets')], input=tar.stdout, check=True)
runs = {'before': [], 'after': []}
order = []
for iteration in range(a.rounds):
    sides = ['before', 'after'] if iteration % 2 == 0 else ['after', 'before']
    order.append(sides)
    for side in sides:
        storage = work / 'storage'
        if storage.exists():
            shutil.rmtree(storage)
        shutil.copytree(a.seed / 'db', storage / 'db')
        shutil.copytree(a.seed / 'storage', storage / 'files')
        source = a.baseline.resolve() if side == 'before' else root
        argv = ['docker', 'run', '--rm', '--entrypoint', '', '--cpuset-cpus', a.cpus]
        for host, target in [(source, '/rails'), (storage, '/rails/storage'), (work / 'tmp', '/rails/tmp'),
                             (work / 'log', '/rails/log'), (work / 'assets', '/rails/public/assets'),
                             (root / 'bench', '/bench'), (a.seed.resolve() / 'labels.json', '/bench-labels.json')]:
            argv += ['-v', f'{host}:{target}']
        for value in ['RAILS_ENV=production', 'SECRET_KEY_BASE=isolated-benchmark-fixture-key', 'DISABLE_SSL=true',
                      'SKIP_TELEMETRY=true', 'RAILS_LOG_LEVEL=fatal', 'BENCH_LABELS=/bench-labels.json']:
            argv += ['-e', value]
        argv += [a.image, 'bundle', 'exec', 'ruby', '-r', '/rails/config/environment.rb', '/bench/message_hot_paths.rb']
        result = subprocess.run(argv, capture_output=True)
        if result.returncode:
            (work / 'probe.stderr').write_bytes(result.stderr)
            raise SystemExit(f'{side} failed; see {work / "probe.stderr"}')
        data = json.loads(result.stdout)
        runs[side].append(data)
        (a.output / f'{side}-{iteration + 1}.json').write_bytes(result.stdout)
        print(f'{iteration + 1}/{a.rounds}: {side}', flush=True)
summary = {}
for name in runs['before'][0]['results']:
    values = {side: [run['results'][name] for run in runs[side]] for side in runs}
    for field in ['body_sha256', 'headers', 'payload_sha256']:
        expected = values['before'][0].get(field)
        if any(row.get(field) != expected for side in values for row in values[side]):
            raise SystemExit(f'{name}: {field} differs; no winning summary written')
    summary[name] = {}
    for side, rows in values.items():
        summary[name][side] = {field: statistics.median(statistics.median(row[field]) for row in rows)
                              for field in ['milliseconds', 'allocations', 'queries'] if field in rows[0]}
        summary[name][side]['round_medians_ms'] = [statistics.median(row['milliseconds']) for row in rows]
    summary[name]['speedup'] = summary[name]['before']['milliseconds'] / summary[name]['after']['milliseconds']
revision = subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD']).decode().strip()
patch = subprocess.check_output(['git', '-C', str(root), 'diff', '--', 'app'])
metadata = {'baseline_sha': a.baseline_ref, 'candidate_head': revision, 'candidate_app_diff_sha256': hashlib.sha256(patch).hexdigest(), 'platform': platform.platform(), 'cpus': a.cpus, 'image': a.image,
            'image_id': subprocess.check_output(['docker', 'image', 'inspect', '-f', '{{.Id}}', a.image]).decode().strip(),
            'body_and_selected_header_parity': 'exact across all measured baseline/candidate requests',
            'order': order, 'ruby': runs['before'][0]['ruby'], 'rails': runs['before'][0]['rails'],
            'limits': 'In-process Rails requests, MemoryStore, frozen clock and CSRF disabled on fixture controllers. Fanout excludes adapter I/O. Not network throughput or connection capacity.'}
(a.output / 'summary.json').write_text(json.dumps({'metadata': metadata, 'results': summary}, indent=2) + '\n')
for name, value in summary.items():
    print(f'{name}: {value["before"]["milliseconds"]:.2f} -> {value["after"]["milliseconds"]:.2f} ms ({value["speedup"]:.2f}x)')
