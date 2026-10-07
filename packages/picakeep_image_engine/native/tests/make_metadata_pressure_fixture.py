"""Write a task-owned metadata pressure fixture; never alter the source."""
import argparse
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--source', required=True, type=Path)
parser.add_argument('--output', required=True, type=Path)
args = parser.parse_args()
if not args.output.is_absolute() or 'picakeep' not in str(args.output):
    raise ValueError('Task-owned absolute output required')
data = args.source.read_bytes()
assert data[:2] == b'\xff\xd8'
args.output.parent.mkdir(parents=True, exist_ok=True)
with args.output.open('xb') as target:
    target.write(data[:2])
    for _ in range(600):
        target.write(b'\xff\xe1\xff\xff' + bytes(65533))
    target.write(data[2:])
print(f'METADATA_PRESSURE bytes={args.output.stat().st_size}')
