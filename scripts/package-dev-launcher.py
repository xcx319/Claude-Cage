#!/usr/bin/env python3
"""Package separate dev/workbench and VM launcher apps from a verified kit.

Build _output/bin/cage and _output/bin/CageDev first. Existing output apps are
never overwritten, and the supplied base bundle is read only.
"""
import argparse
from pathlib import Path
import plistlib
import re
import shutil
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--base', required=True, type=Path)
parser.add_argument('--destination', required=True, type=Path)
parser.add_argument('--version', required=True)
parser.add_argument('--build', required=True, type=int)
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
if args.build < 1 or not re.fullmatch(r'\d+\.\d+\.\d+-dev\.\d+', args.version):
    parser.error('Use a positive build number and x.y.z-dev.n version')
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(args.base)], check=True)
targets = [args.destination / f'Cage-Dev-{args.build}.app', args.destination / f'Cage-VM-Launcher-{args.build}.app']
if any(p.exists() for p in targets):
    parser.error('Destination already exists; choose a new build number')
for target, launcher in zip(targets, (False, True)):
    shutil.copytree(args.base, target, symlinks=True)
    resource = target / 'Contents/Resources'
    helper = resource / 'CageVM.app'
    shutil.copy2(root / '_output/bin/cage', resource / 'cage')
    shutil.copy2(root / '_output/bin/cage', helper / 'Contents/MacOS/cage')
    shutil.copy2(root / '_output/bin/CageDev', target / 'Contents/MacOS/Cage')
    for p in (target / 'Contents/Info.plist', helper / 'Contents/Info.plist'):
        info = plistlib.loads(p.read_bytes())
        info['CFBundleVersion'] = str(args.build)
        if p == target / 'Contents/Info.plist':
            info.update(CageVersion=args.version, CageVMLauncher=launcher,
                        CFBundleIdentifier='io.github.lee-xeo.claude-cage.dev' + ('.launcher' if launcher else ''),
                        CFBundleName='Cage VM Launcher' if launcher else 'Cage Dev',
                        CFBundleDisplayName='Cage 虚拟机启动器' if launcher else 'Cage Dev')
        else:
            info['CFBundleIdentifier'] = 'io.github.lee-xeo.claude-cage.dev' + ('.launcher' if launcher else '') + '.vm'
        p.write_bytes(plistlib.dumps(info))
    subprocess.run(['codesign', '--force', '--sign', '-', '--entitlements', str(root / 'third_party/lima/vz.entitlements'), str(helper)], check=True)
    subprocess.run(['codesign', '--force', '--sign', '-', str(target)], check=True)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(target)], check=True)
    print(target, flush=True)
