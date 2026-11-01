#!/usr/bin/env python3
"""Compile the production FilterChain against host Metal, with a fault-only allocator seam.
Use --baseline REV to demonstrate the real invalid-descriptor abort in that revision.
"""
import argparse
import os
from pathlib import Path
import resource
import subprocess
import tempfile

root = Path(__file__).resolve().parents[3]
shader = root / 'Source/iOS/App/Common/Swift/Shaders'
parser = argparse.ArgumentParser()
parser.add_argument('--baseline', help='Revision to reproduce the invalid-descriptor abort')
parser.add_argument('--debug', action='store_true', help='Compile DEBUG diagnostics and regression fixtures')
args = parser.parse_args()

def run(command, **kwargs):
    return subprocess.run(command, check=True, **kwargs)

with tempfile.TemporaryDirectory(prefix='icube-shader-textures-') as temp:
    build = Path(temp)
    path = str((shader / 'FilterChain.swift').relative_to(root))
    source = (subprocess.check_output(['git', 'show', f'{args.baseline}:{path}'], cwd=root).decode()
              if args.baseline else (shader / 'FilterChain.swift').read_text())
    # Only inject recoverable allocation failure; descriptor validation is still
    # performed by the real driver for every allocation that reaches Metal.
    needle = 'device.makeTexture(descriptor: td)'
    assert source.count(needle) == 1
    source = source.replace(needle, 'auditMakeTexture(device, td)')
    if not args.baseline:
        faults = {
            'device.makeBuffer(length: sizeMax, options: [.storageModePrivate])':
                'auditMakeClearBuffer(device, sizeMax)',
            'let bce = commandBuffer.makeBlitCommandEncoder() else { return false }':
                'let bce = auditMakeClearEncoder(commandBuffer) else { return false }',
        }
        for needle, replacement in faults.items():
            assert source.count(needle) == 1
            source = source.replace(needle, replacement)
    (build / 'FilterChain.swift').write_text(source)
    harness = (Path(__file__).parent / 'main.swift').read_text()
    if args.baseline:
        # Baseline lacks the new dimension validator; only the crash fixture runs.
        harness = harness[:harness.index('// Finite checks')]
    (build / 'main.swift').write_text(harness)
    run(['xcrun', '-sdk', 'macosx', 'metal', '-c', str(shader / 'Shaders.metal'), '-o', str(build / 'Shaders.air')])
    run(['xcrun', '-sdk', 'macosx', 'metallib', str(build / 'Shaders.air'), '-o', str(build / 'default.metallib')])
    names = ['CompiledShader', 'CompiledShaderContainer', 'CompilerEnums', 'ShaderPassBindings',
             'ShaderPassSemantics', 'ShaderParameter', 'Matrix']
    run(['xcrun', 'swiftc', *(['-D', 'DEBUG'] if args.debug else []),
         str(build / 'FilterChain.swift'), str(build / 'main.swift'),
         *[str(shader / f'{name}.swift') for name in names], '-o', str(build / 'audit')])
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    command = [str(build / 'audit')]
    if args.baseline:
        command.append('--baseline-crash')
    result = subprocess.run(command, env={**os.environ, 'MTL_DEBUG_LAYER': '1'}, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    print(result.stdout)
    if args.baseline:
        assert result.returncode == -6 and 'validateWithDevice' in result.stdout, result.returncode
        print('PASS: baseline reproduced native Metal descriptor validation SIGABRT')
    else:
        result.check_returncode()
