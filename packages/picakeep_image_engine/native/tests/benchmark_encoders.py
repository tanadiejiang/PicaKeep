"""Same-pixel cover encoder/decoder comparisons; 30 samples per candidate."""
import ctypes as c
import io
import json
import os
import time
from pathlib import Path
import numpy as np
from PIL import Image

root = Path(__file__).resolve().parents[1]
library = c.CDLL(os.environ['PICAKEEP_IMAGE_ENGINE_LIBRARY'])
class Request(c.Structure):
    _fields_ = [(k,c.c_uint32) for k in ['width','height','stride','format','quality','lossless']] + [(k,c.c_uint64) for k in ['input_bytes','memory','max_output']] + [('token',c.c_void_p)]
class Result(c.Structure):
    _fields_ = [('bytes',c.POINTER(c.c_uint8))] + [(k,c.c_uint64) for k in ['length','peak','micros']] + [('format',c.c_uint32)]
library.pki_encode_rgba.argtypes = [c.POINTER(c.c_uint8),c.POINTER(Request),c.POINTER(Result),c.c_char_p,c.c_uint64]
library.pki_encoded_release.argtypes = [c.POINTER(Result)]

rows = []
fixtures = Path(os.environ.get('PICAKEEP_IMAGE_ENGINE_FIXTURES', 'E:/picakeep-image-pipeline-022-fixtures'))
source = Image.open(fixtures/'3000x4000.png').convert('RGBA')
output = Path(os.environ.get('PICAKEEP_IMAGE_ENGINE_REPORT_DIR', Path(os.environ['PICAKEEP_IMAGE_ENGINE_LIBRARY']).parent.parent))
output.mkdir(exist_ok=True,parents=True)
for edge in [192,384,768]:
    cover=source.resize((int(edge*.75),edge),Image.Resampling.LANCZOS)
    pixels=np.ascontiguousarray(np.array(cover),dtype=np.uint8)
    for name,fmt,quality,lossless in [('PNG',2,100,0),('JPEG85',1,85,0),('WebP85',3,85,0),('WebP-lossless',3,85,1)]:
        times=[]; data=None; peak=0
        req=Request(cover.width,cover.height,cover.width*4,fmt,quality,lossless,pixels.nbytes,128*1024*1024,32*1024*1024,None)
        for i in range(31):
            result=Result(); error=c.create_string_buffer(512)
            status=library.pki_encode_rgba(pixels.ctypes.data_as(c.POINTER(c.c_uint8)),c.byref(req),c.byref(result),error,512)
            assert status==0,(name,status,error.value)
            try:
                if i: times.append(result.micros/1000)
                data=c.string_at(result.bytes,result.length); peak=max(peak,result.peak)
            finally: library.pki_encoded_release(c.byref(result))
        decode=[]
        for i in range(31):
            start=time.perf_counter_ns(); restored=np.array(Image.open(io.BytesIO(data)).convert('RGBA')); elapsed=(time.perf_counter_ns()-start)/1e6
            if i: decode.append(elapsed)
        delta=np.abs(restored.astype(np.int16)-pixels.astype(np.int16))
        mse=float(np.mean(delta[:,:,:3].astype(float)**2))
        row=dict(edge=edge,format=name,size=len(data),encode_p50_ms=float(np.median(times)),encode_p95_ms=float(np.percentile(times,95)),decode_p50_ms=float(np.median(decode)),peak=peak,max_difference=int(delta.max()),psnr_db=None if mse==0 else float(10*np.log10(255**2/mse)))
        rows.append(row); print(row,flush=True)
        (output/f'cover-{edge}-{name}.bin').write_bytes(data)
    # Alpha contract and max-output limit are enforced by the actual codec API.
    alpha=pixels.copy(); alpha[:,:,3]=np.arange(cover.width,dtype=np.uint16)[None,:]%256
    req=Request(cover.width,cover.height,cover.width*4,1,85,0,alpha.nbytes,128*1024*1024,32*1024*1024,None)
    result=Result(); error=c.create_string_buffer(512)
    status=library.pki_encode_rgba(alpha.ctypes.data_as(c.POINTER(c.c_uint8)),c.byref(req),c.byref(result),error,512)
    assert status==4 and not result.bytes
    req.format=3; req.lossless=1
    status=library.pki_encode_rgba(alpha.ctypes.data_as(c.POINTER(c.c_uint8)),c.byref(req),c.byref(result),error,512)
    assert status==0,error.value
    try: restored=np.array(Image.open(io.BytesIO(c.string_at(result.bytes,result.length))).convert('RGBA'))
    finally: library.pki_encoded_release(c.byref(result))
    assert np.array_equal(restored,alpha)
    req.max_output=32
    status=library.pki_encode_rgba(alpha.ctypes.data_as(c.POINTER(c.c_uint8)),c.byref(req),c.byref(result),error,512)
    assert status==3 and not result.bytes
(output/'cover-encoder-benchmark.json').write_text(json.dumps(rows,indent=2),encoding='utf-8')
print('PASS: alpha exact lossless, JPEG transparency rejection, max-output budget.')
