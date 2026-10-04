#!/usr/bin/env python3
"""Compare warm production Puma/Redis requests using isolated seeded containers."""
import argparse
import json
import os
import pathlib
import shutil
import socket
import subprocess
import time
import urllib.request

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--baseline', type=pathlib.Path, required=True)
p.add_argument('--seed', type=pathlib.Path, required=True)
p.add_argument('--loadgen', type=pathlib.Path, required=True)
p.add_argument('--output', type=pathlib.Path, required=True)
p.add_argument('--image', default='campfire-reference:app')
p.add_argument('--cpus', default='8-11')
p.add_argument('--rounds', type=int, default=2)
p.add_argument('--duration', type=int, default=3)
p.add_argument('--paths', default='room,messages,sidebar,search')
p.add_argument('--concurrencies', default='1,16')
a = p.parse_args()
if a.rounds < 2 or a.rounds % 2:
    p.error('--rounds must be even and at least 2')
root = pathlib.Path(__file__).resolve().parents[1]
work = root / 'tmp/rails-optimization/http'
work.mkdir(parents=True, exist_ok=True)
a.output.mkdir(parents=True, exist_ok=True)
labels = json.loads((a.seed / 'labels.json').read_text())
network = f'cf-ruby-bench-{os.getpid()}'
redis = network + '-redis'
app = network + '-app'
paths = {'room': f"/rooms/{labels['rooms.watercooler']}",
         'messages': f"/rooms/{labels['rooms.watercooler']}/messages?before={labels['messages.busy_060']}",
         'sidebar': '/users/me/sidebar', 'search': '/searches?q=coffee'}
def run(argv):
    return subprocess.run(argv, capture_output=True, check=True).stdout

def stop_app():
    subprocess.run(['docker', 'rm', '-f', app], capture_output=True)

try:
    run(['docker', 'network', 'create', network])
    run(['docker', 'run', '-d', '--name', redis, '--network', network, 'redis:7-alpine'])
    for iteration in range(a.rounds):
        order = ['before', 'after'] if iteration % 2 == 0 else ['after', 'before']
        for side in order:
            stop_app()
            data = work / 'data'
            if data.exists():
                shutil.rmtree(data)
            shutil.copytree(a.seed / 'db', data / 'storage/db')
            shutil.copytree(a.seed / 'storage', data / 'storage/files')
            for name in ['tmp/pids', 'log']:
                (data / name).mkdir(parents=True, exist_ok=True)
            run(['docker', 'exec', redis, 'redis-cli', 'FLUSHALL'])
            with socket.socket() as sock:
                sock.bind(('127.0.0.1', 0))
                port = sock.getsockname()[1]
            base = f'http://127.0.0.1:{port}'
            source = a.baseline.resolve() if side == 'before' else root
            argv = ['docker', 'run', '-d', '--name', app, '--entrypoint', '', '--network', network,
                    '--cpuset-cpus', a.cpus, '-p', f'127.0.0.1:{port}:3000']
            for host, target in [(source, '/rails'), (data / 'storage', '/rails/storage'),
                                 (data / 'tmp', '/rails/tmp'), (data / 'log', '/rails/log'),
                                 (root / 'tmp/rails-optimization/runtime/assets', '/rails/public/assets')]:
                argv += ['-v', f'{host}:{target}']
            for value in ['RAILS_ENV=production', 'SECRET_KEY_BASE=isolated-benchmark-fixture-key',
                          'DISABLE_SSL=true', 'SKIP_TELEMETRY=true', 'RAILS_LOG_LEVEL=fatal',
                          'WEB_CONCURRENCY=1', 'JOB_CONCURRENCY=1', 'RAILS_MAX_THREADS=5',
                          f'REDIS_URL=redis://{redis}:6379/0']:
                argv += ['-e', value]
            argv += [a.image, 'bundle', 'exec', 'puma', '-C', 'config/puma.rb']
            run(argv)
            deadline = time.monotonic() + 45
            while True:
                try:
                    with urllib.request.urlopen(base + '/up', timeout=1) as response:
                        if response.status == 200:
                            break
                except (OSError, urllib.error.URLError):
                    pass
                if time.monotonic() > deadline:
                    (work / 'server.log').write_bytes(run(['docker', 'logs', app]))
                    raise RuntimeError('server did not become ready; see server.log')
                time.sleep(0.1)
            cookie = json.loads(run([str(a.loadgen), 'login', '--base', base,
                                     '--email', labels['emails.david'], '--password', labels['passwords.all']]))['cookie']
            results = {}
            for name in a.paths.split(','):
                path = paths[name]
                warmup = json.loads(run([str(a.loadgen), 'http', '--base', base, '--cookie', cookie, '--path', path,
                                        '--conc', '1', '--duration', '3', '--gzip', '0']))
                if warmup['errors'] or set(warmup['statuses']) != {'200'}:
                    raise RuntimeError(f'{name}: warmup failed: {warmup["statuses"]}')
                for conc in map(int, a.concurrencies.split(',')):
                    value = json.loads(run(['taskset', '-c', '12-15', str(a.loadgen), 'http',
                                            '--base', base, '--cookie', cookie, '--path', path,
                                            '--conc', str(conc), '--duration', str(a.duration), '--gzip', '0']))
                    if value['errors'] or set(value['statuses']) != {'200'}:
                        raise RuntimeError(f'{name}: load failed: {value["statuses"]}')
                    results[f'{name}_{conc}'] = value
            (a.output / f'{side}-{iteration + 1}.json').write_text(json.dumps(results, indent=2) + '\n')
            print(f'{iteration + 1}/{a.rounds}: {side}', flush=True)
finally:
    stop_app()
    subprocess.run(['docker', 'rm', '-f', redis], capture_output=True)
    subprocess.run(['docker', 'network', 'rm', network], capture_output=True)
