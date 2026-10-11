#!/usr/bin/env python3
"""Create deterministic engine cases from CMDY's own regression history."""
import argparse
import hashlib
import json
import pathlib
import random
import struct
import itertools

p = argparse.ArgumentParser()
p.add_argument('--repo', type=pathlib.Path, required=True)
p.add_argument('--output', type=pathlib.Path, required=True)
p.add_argument('--performance-corpora', type=pathlib.Path)
args = p.parse_args()
cases = []
sources = {}

def feed(data, checkpoint=True):
    if isinstance(data, str): data = data.encode()
    return {'op': 'feed', 'bytes': list(data), 'checkpoint': checkpoint}

def add(name, data, cols=7, rows=4, history=8, chunk=None, checkpoints=True, detailed=False):
    if isinstance(data, str): data = data.encode()
    chunk = chunk or max(1, len(data))
    steps = [feed(data[i:i+chunk], checkpoints or i+chunk >= len(data)) for i in range(0,len(data),chunk)]
    if not steps: steps = [feed(b'')]
    cases.append({'name':name, 'cols':cols, 'rows':rows, 'scrollback':history, 'detailed':detailed, 'steps':steps})

curated = {
 'plain-crlf': 'one\r\ntwo\r\nthree\r\nfour\r\nfive\r\n',
 'tabs-pending': 'ABCDEFG\t\x1b[I\x1b[2Z\tX\bY',
 'sgr-colon': '\x1b[4:3;38:2::1:2:3mA\x1b[48;5;42mB\x1b[58:5:201mC\x1b[0mD',
 'csi-flat-colon': '\x1b[3:2H!\x1b[:3mX\x1b[?1mY',
 'cursor-pending': 'ABCDEFG\x1b[A\x1b[B\x1b[G\x1b[H\x1b[2;3f!',
 'origin-margins': '\x1b[2;3r\x1b[?69h\x1b[3;5s\x1b[?6h\x1b[20;20H!\x1b[20;20f?\x1b[1Gx',
 'reversed-margins': '\x1b[?69h\x1b[6;2s\x1b[2GABCDEFG\r\n!',
 'zero-margins': '\x1b[?69h\x1b[4;0sABCDEFG\x1b[;s\r\nZ',
 'decbi-decfi': 'ABCDEF\x1b[3G\x1b6\x1b[7G\x1b9\x1b9\x1b[?69h\x1b[2;4s\x1b[2G\x1b6\x1b[4G\x1b9',
 'ich-dch-owner': 'AB❤CD\x1b[3G\x1b[@\x1b[P\ufe0f\u0301',
 'insert-delete-line': 'A\r\nB\r\nC\r\nD\x1b[2;1H\x1b[L\x1b[M\u0301',
 'margin-virtual-cells': 'AAAAAAA\r\nBBBBBBB\r\nCCCCCCC\r\nDDDDDDD\x1b[?69h\x1b[2;4s\x1b[43m\x1b[2;2H\x1b[M\x1b[L\x1b[M\u0301',
 'erase-pen': '\x1b[1;31;44mABCDE\x1b[3G\x1b[K\x1b[1J\x1b[2J\x1b[3J',
 'scroll-regions': 'A\r\nB\r\nC\r\nD\x1b[2;3r\x1b[2S\x1b[T\x1b[?S\x1b[?T',
 'saved-cursor': '\x1b8ABCDEFG\x1b[?7h\x1b7\x1b[2;2H\x1b8X\x1b[s\x1b[H\x1b[uY',
 'ris-alt-slots': '\x1b[?25l\x1b[?45h\x1b[20h\x1b[?1049hALT\x1b[?1049l\x1bc\bX\nY',
 'soft-reset': '\x1b[?6;69h\x1b[2;4s\x1b[2;3r\x1b[31;44m\x1b[4h\x1b[!pX',
 'alternate-modes': 'NORMAL\x1b[?47hALT\x1b[?47l!\x1b[?1049hSECOND\x1b[?1049l?',
 'mouse-and-keyboard': '\x1b[?1;1000;1006;1004;2004;2026h\x1b[>7u\x1b[?u\x1b[=2;2u\x1b[<u\x1b[?u',
 'reports': '\x1b[5n\x1b[6n\x1b[?6n\x1b[c\x1b[>c\x1b[?7$p\x1b[4$p\x1b[18t\x1bP$qm\x1b\\',
 'title-stack': '\x1b]0;hello\x07\x1b[22t\x1b]2;world\x1b\\\x1b[23t',
 'directory-notification': '\x1b]7;file://host/work/project\x07\x1b]9;attention\x07\x1b]777;notify;Title;Body\x07',
 'hyperlink': '\x1b]8;id=x;https://example.invalid/a\x1b\\LINK\x1b]8;;\x1b\\plain',
 'blocks': '\x1b]133;A\x07$ \x1b]133;B\x07echo hi\x1b]133;C\x07\r\nhi\r\n\x1b]133;D;7\x07\x1b]133;A\x07$ \x1b]133;D;0\x07',
 'unicode-joins': 'e\u0301 中文 Ελληνικά العربية 👩🏽\u200d💻 🏳️\u200d🌈 🇸🇪 1\ufe0f\u20e3',
 'selector-motion': '❤\x1b[2C\ufe0f\x1b[2D\ufe0e\r\n❤\x1b[A\ufe0f\x1b[B\u0301',
 'selector-margins': '\x1b[?69h\x1b[2;4s\x1b[4G❤\ufe0f\x1b[2G❤\x1b6\ufe0f\x1b9\u0301',
 'reverse-index-owner': '❤\x1b[H\x1bM\ufe0f\x1b[?1049h❤\x1b[H\x1bM\ufe0f\x1b[?1049l\u0301',
 'sixel': '\x1bPq#1;2;100;0;0~\x1b\\X',
 'kitty-rgba': '\x1b_Ga=T,f=32,s=1,v=1,i=7,p=2;AAAA/w==\x1b\\X\x1b_Ga=d,d=i,i=7\x1b\\',
 'kitty-query': '\x1b_Ga=q,f=32,s=1,v=1,i=9;AAAA/w==\x1b\\',
 'dec-align': '\x1b#8\x1b[2;3H\x1b[2K',
 'rep-owner': 'e\u0301\x1b[3b\x1b[3G\x1b[2b',
 'osc-abort': '\x1b]0;discard\x1b[31mX\x1b]0;title\x18Y',
 'dcs-passthrough': '\x1bP$qm\x1b\\\x1bP1;2qabc\x1bQtail\x18Z',
 'malformed': b'\xc0\xc1\xe2\x07\x82\xac\xed\xa0\x80\xf0\x9f\x1b[31m\x92\xbbX',
}
for label, data in curated.items():
    for cols, rows in [(1,2),(7,4),(12,6)]:
        for chunk in [1,7,65536]: add(f'{label}-{cols}x{rows}-chunk{chunk}', data, cols, rows, chunk=chunk)

def recorded(data):
    if not data.startswith((b'CMDY-REPLAY ',b'TERMITE-REPLAY ')): return 80,24,[data]
    header, data=data.split(b'----\n',1)
    settings=dict(token.split(b'=',1) for line in header.splitlines() for token in line.split() if b'=' in token)
    chunks=[]; cursor=0
    while cursor<len(data):
        n=struct.unpack_from('<I',data,cursor)[0]; cursor+=4
        assert cursor+n<=len(data)
        chunks.append(data[cursor:cursor+n]); cursor+=n
    return int(settings[b'cols']),int(settings[b'rows']),chunks

for path in sorted((args.repo/'Tests/corpus').glob('*.term')):
    data=path.read_bytes(); sources[str(path.relative_to(args.repo))]=hashlib.sha256(data).hexdigest()
    cols,rows,chunks=recorded(data)
    cases.append({'name':'recorded-'+path.stem,'cols':cols,'rows':rows,'scrollback':128,
                  'steps':[feed(part, i==len(chunks)-1) for i,part in enumerate(chunks)]})
for path in sorted((args.repo/'Tests/corpus/regressions').glob('*.bin')):
    data=path.read_bytes(); sources[str(path.relative_to(args.repo))]=hashlib.sha256(data).hexdigest()
    for cols,rows in [(1,2),(7,4),(80,24)]:
        for chunk in [1,65536]: add(f'{path.stem}-{cols}x{rows}-chunk{chunk}',data,cols,rows,chunk=chunk)

rng=random.Random(20260911)
pieces=['abc','XYZ','❤','\ufe0f','\u0301','👩\u200d💻','\r','\n','\t','\b',
        '\x1b[A','\x1b[B','\x1b[C','\x1b[D','\x1b[H','\x1b[2;3H','\x1b[@','\x1b[P','\x1b[L','\x1b[M',
        '\x1b[31m','\x1b[44m','\x1b[0m','\x1b[K','\x1b[2J','\x1b[?7l','\x1b[?7h','\x1b[?69h','\x1b[?69l',
        '\x1b[2;4s','\x1b[2;3r','\x1b6','\x1b9','\x1bM','\x1bD','\x1b7','\x1b8','\x1b[?1049h','\x1b[?1049l']
for seed in range(32):
    cols,rows=rng.choice([(1,2),(7,4),(12,6)])
    steps=[feed(rng.choice(pieces)) for _ in range(32)]
    cases.append({'name':f'mixed-seed-20260911-{seed}','cols':cols,'rows':rows,'scrollback':8,'steps':steps})
for cols,rows in [(1,2),(7,4),(12,6)]:
    cases.append({'name':f'reflow-host-{cols}x{rows}','cols':cols,'rows':rows,'scrollback':12,'steps':[
        feed('one two three four five\r\ne\u0301 中文 👩\u200d💻'),
        {'op':'host_message','text':'A host message with several words that wrap.'},
        {'op':'resize','cols':cols+3,'rows':rows+1},
        {'op':'viewport','row':0},feed('\x1b[?1049hALT'),
        {'op':'resize','cols':max(1,cols-1),'rows':max(1,rows-1)},feed('\x1b[?1049l'),
        {'op':'resize','cols':cols,'rows':rows}]})

# Original OwnerOutput's direct and weak callbacks differ when callers replace
# the embedded parser delegate. Chunking and fast-path controls are observable.
owner_bytes = ('A\r\nB\r\n\r\n\x07\t\b éABC界DEF\x1b[31mX\x1b[H\x1b[38:5:2mY'
               '\x1b]0;title\x07\x1bP$qm\x1b\\\x1b_Gignored\x1b\\\x1b7\x1b8'
               '\x1b[' + '1;' * 32 + '1m\x1b[' + '9' * 256 + 'mZ').encode()
owner_bytes += b'\xc3\x07\xa9\xc0\xe2\x1b[0m\x92\xbb'
for mode in ['owner','custom','nil']:
    for ascii_fast,utf8_fast,batch_fast,csi_fast in itertools.product([False,True], repeat=4):
        for chunk in [1,7,65536]:
            add(f'owner-route-{mode}-{int(ascii_fast)}{int(utf8_fast)}{int(batch_fast)}{int(csi_fast)}-chunk{chunk}',
                owner_bytes,7,4,chunk=chunk)
            cases[-1]['parser_delegate'] = mode
            cases[-1]['parser_options'] = [ascii_fast,utf8_fast,batch_fast,csi_fast]

if args.performance_corpora:
    for path in sorted(args.performance_corpora.glob('*.bin')):
        data=path.read_bytes()
        sources[str(path.resolve())]=hashlib.sha256(data).hexdigest()
        add('performance-'+path.stem,data,120,36,1000,1024,False)
assert len({c['name'] for c in cases})==len(cases)
args.output.parent.mkdir(parents=True,exist_ok=True)
with args.output.open('x') as stream: json.dump(cases,stream,separators=(',',':'))
metadata={'cases':len(cases),'checkpoints':sum(1+sum(s.get('checkpoint',True) for s in c['steps']) for c in cases),
          'source_files':sources,'input_sha256':hashlib.sha256(args.output.read_bytes()).hexdigest(),
          'builder_sha256':hashlib.sha256(pathlib.Path(__file__).read_bytes()).hexdigest(),
          'notes':['Semantic comparison only; no timing or Ghostty implementation inputs.',
                   'The retained 539-test Swift suite remains an additional independent integration requirement.']}
with args.output.with_suffix('.manifest.json').open('x') as stream: json.dump(metadata,stream,indent=2)
print(json.dumps({key:metadata[key] for key in ['cases','checkpoints','input_sha256']}))
