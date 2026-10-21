#!/usr/bin/env python3
"""FEX-specific JVM workarounds, applied to the upstream PZ launcher JSON."""
import json
import os
import stat
import sys
import tempfile

FIXES = [
    '-XX:+UseParallelGC',
    '-XX:TieredStopAtLevel=1',
    '-Dsun.reflect.noInflation=true',
    '-Djdk.reflect.useDirectMethodHandle=false',
    '-XX:CompileCommand=exclude,java/lang/Class,reflectionData',
    '-XX:CompileCommand=exclude,java/lang/invoke/*,*',
    '-XX:CompileCommand=exclude,zombie/network/GameServer.shouldSendWorldMapPlayerPosition',
    '-XX:CompileCommand=dontinline,zombie/network/GameServer.shouldSendWorldMapPlayerPosition',
]

def main():
    if len(sys.argv) != 3:
        sys.exit('Usage: patch-jvm.py ProjectZomboid64.json heap_size_gb')
    path, heap = sys.argv[1:]
    heap_gb = int(heap)
    if not 2 <= heap_gb <= 64:
        sys.exit('Heap must be 2-64 GiB')
    with open(path, encoding='utf-8') as stream:
        doc = json.load(stream)
    if not isinstance(doc.get('vmArgs'), list):
        sys.exit('Refusing to change JSON without vmArgs list')
    args = [arg for arg in doc['vmArgs'] if isinstance(arg, str)]
    args = [arg for arg in args if not arg.startswith(('-Xms', '-Xmx'))
            and arg not in ('-XX:+UseZGC', '-XX:+UseG1GC', '-XX:+UseShenandoahGC', '-XX:+UseSerialGC')]
    for flag in FIXES:
        if flag not in args:
            args.append(flag)
    args.extend(['-Xms2g', '-Xmx{}g'.format(heap_gb)])
    doc['vmArgs'] = args
    info = os.stat(path)
    directory = os.path.dirname(os.path.abspath(path))
    handle, temp_path = tempfile.mkstemp(prefix='.ProjectZomboid64-', suffix='.json', dir=directory)
    try:
        with os.fdopen(handle, 'w', encoding='utf-8') as out:
            json.dump(doc, out, indent=2)
            out.write('\n')
        os.chmod(temp_path, stat.S_IMODE(info.st_mode))
        if os.geteuid() == 0:
            os.chown(temp_path, info.st_uid, info.st_gid)
        os.replace(temp_path, path)
    finally:
        if os.path.exists(temp_path):
            os.unlink(temp_path)
    print('Updated {} ({} GiB max heap; FEX safeguards)'.format(path, heap_gb))

if __name__ == '__main__':
    main()
