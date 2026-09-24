#!/usr/bin/env python3
"""Read-only guard for the attached volume and resolved core Compose binds."""
import json
import os
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
EXPECTED = pathlib.Path('/data/surf-biomero-storage')
REQUIRED = {
    'database': {'/var/lib/postgresql/data': 'database'},
    'database-biomero': {'/var/lib/postgresql/data': 'database-biomero'},
    'omeroserver': {'/OMERO': 'omero', '/data': 'L-Drive'},
    'omeroworker-1': {'/OMERO': 'omero', '/data': 'L-Drive'},
    'biomeroworker': {'/OMERO': 'omero', '/data': 'L-Drive'},
    'omeroweb': {'/data': 'L-Drive'},
    'biomero-importer': {'/OMERO': 'omero', '/data': 'L-Drive'},
}


def run(*args):
    return subprocess.run(args, cwd=ROOT, text=True, capture_output=True, check=True).stdout.strip()


def main():
    try:
        values = [line.partition('=')[2] for line in (ROOT / '.env').read_text().splitlines()
                  if line.startswith('OMERO_DATA_PATH=')]
        if len(values) != 1 or pathlib.Path(values[0]) != EXPECTED:
            raise ValueError('OMERO_DATA_PATH must resolve to the expected attached volume')
        mount = run('findmnt', '-M', str(EXPECTED), '-n', '-o', 'TARGET,SOURCE,FSTYPE').split()
        if len(mount) != 3 or mount[0] != str(EXPECTED) or mount[2] != 'xfs':
            raise ValueError('expected XFS filesystem is not mounted at the storage path')
        device = EXPECTED.stat().st_dev
        config = json.loads(run('sudo', '-n', 'docker', 'compose', 'config', '--format', 'json'))
        for service, targets in REQUIRED.items():
            mounts = {v.get('target'): v.get('source') for v in
                      config['services'][service].get('volumes', []) if v.get('type') == 'bind'}
            for target, folder in targets.items():
                source = EXPECTED / folder
                if mounts.get(target) != str(source):
                    raise ValueError(f'{service}:{target} does not bind {source}')
                if not source.resolve().is_relative_to(EXPECTED) or (source.exists() and source.stat().st_dev != device):
                    raise ValueError(f'{service}:{target} resolves outside the attached filesystem')
        print(f'PASS: attached XFS {mount[1]} mounted at {EXPECTED}; all required core storage binds resolve there')
    except (OSError, KeyError, ValueError, subprocess.CalledProcessError) as exc:
        print(f'FAIL: storage mount gate: {exc}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
