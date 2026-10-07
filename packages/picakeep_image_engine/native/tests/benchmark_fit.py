"""Compare cold fit, raw preparation and warm fit without Flutter/GPU work."""
import argparse
import ctypes as c
import json
import os
from pathlib import Path
import statistics

parser = argparse.ArgumentParser()
parser.add_argument('source', type=Path)
parser.add_argument('--width', type=int, default=750)
parser.add_argument('--height', type=int, default=1000)
parser.add_argument('--samples', type=int, default=5)
parser.add_argument('--label', default='before')
args = parser.parse_args()
root = Path(os.environ.get('PICAKEEP_IMAGE_ENGINE_ARTIFACTS', 'E:/picakeep-native-022-artifacts'))
root.mkdir(parents=True, exist_ok=True)
library = c.CDLL(os.environ['PICAKEEP_IMAGE_ENGINE_LIBRARY'])

class Metadata(c.Structure):
    _fields_ = [(k, c.c_uint32) for k in ['width','height','ew','eh','format','orientation','animated','depth','profile']] + [('estimate',c.c_uint64)]
class Request(c.Structure):
    _fields_ = [(k,c.c_uint32) for k in ['x','y','width','height','ow','oh']] + [('memory',c.c_uint64),('disk',c.c_uint64),('token',c.c_void_p)]
class Result(c.Structure):
    _fields_ = [('pixels',c.POINTER(c.c_uint8)),('length',c.c_uint64)] + [(k,c.c_uint32) for k in ['width','height','stride']] + [(k,c.c_uint64) for k in ['peak','disk','micros']] + [('backend',c.c_char_p)]
library.pki_probe.argtypes=[c.c_char_p,c.POINTER(Metadata),c.c_char_p,c.c_uint64]
library.pki_decode_region.argtypes=[c.c_char_p,c.c_char_p,c.POINTER(Request),c.POINTER(Result),c.c_char_p,c.c_uint64]
library.pki_release.argtypes=[c.POINTER(Result)]
error=c.create_string_buffer(512);metadata=Metadata()
assert library.pki_probe(str(args.source).encode(),c.byref(metadata),error,512)==0,error.value

def decode(backing, width, height, save=False):
    req=Request(0,0,metadata.width,metadata.height,width,height,896<<20,1536<<20,None)
    output=Result()
    status=library.pki_decode_region(str(args.source).encode(),str(backing).encode(),c.byref(req),c.byref(output),error,512)
    assert status==0,(status,error.value)
    try:
        if save:(root/f'fit-{args.label}-{args.source.stem}-{width}x{height}.rgba').write_bytes(c.string_at(output.pixels,output.length))
        return dict(micros=output.micros,peak=output.peak,disk=output.disk,backend=output.backend.decode())
    finally:library.pki_release(c.byref(output))

data=dict(source=str(args.source),sourceWidth=metadata.width,sourceHeight=metadata.height,outputWidth=args.width,outputHeight=args.height,label=args.label,samples=args.samples,runs={})
backing=root/f'picakeep-fit-benchmark-{args.source.stem}-{args.width}x{args.height}.raw'
for mode in ['fit-cold','prepare-raw','fit-warm']:
    samples=[]
    for i in range(args.samples):
        if mode!='fit-warm' and backing.exists():backing.unlink()
        samples.append(decode(backing,1 if mode=='prepare-raw' else args.width,1 if mode=='prepare-raw' else args.height,save=mode=='fit-cold' and i==0))
    data['runs'][mode]=dict(p50Micros=statistics.median(s['micros'] for s in samples),measurements=samples)
if backing.exists():backing.unlink()
report=root/f'fit-{args.label}-{args.source.stem}-{args.width}x{args.height}.json'
report.write_text(json.dumps(data,indent=2),encoding='utf-8')
print(json.dumps(data,indent=2))
