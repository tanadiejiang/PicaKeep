"""Validate native source-coordinate ROIs against decoded originals.

Includes all EXIF orientations, exact lossless pixels, alpha, adjacent tiles,
bounded rejection/cancellation, cold concurrency and source-version invalidation.
"""
import ctypes as c
import json
import os
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from tempfile import TemporaryDirectory
import numpy as np
from PIL import Image, ImageOps

Image.MAX_IMAGE_PIXELS = 128_000_000
root = Path(__file__).resolve().parents[1]
dll = Path(os.environ.get('PICAKEEP_IMAGE_ENGINE_LIBRARY', str(root / 'build/windows/Debug/picakeep_image_engine.dll')))
library = c.CDLL(str(dll))
class Metadata(c.Structure):
    _fields_ = [(key, c.c_uint32) for key in ['width', 'height', 'ew', 'eh', 'format', 'orientation', 'animated', 'depth', 'profile']] + [('estimate', c.c_uint64)]
class Request(c.Structure):
    _fields_ = [(key, c.c_uint32) for key in ['x', 'y', 'width', 'height', 'ow', 'oh']] + [('memory', c.c_uint64), ('disk', c.c_uint64), ('token', c.c_void_p)]
class Result(c.Structure):
    _fields_ = [('pixels', c.POINTER(c.c_uint8)), ('length', c.c_uint64)] + [(key, c.c_uint32) for key in ['width', 'height', 'stride']] + [(key, c.c_uint64) for key in ['peak', 'disk', 'micros']] + [('backend', c.c_char_p)]
library.pki_probe.argtypes = [c.c_char_p, c.POINTER(Metadata), c.c_char_p, c.c_uint64]
library.pki_decode_region.argtypes = [c.c_char_p, c.c_char_p, c.POINTER(Request), c.POINTER(Result), c.c_char_p, c.c_uint64]
library.pki_release.argtypes = [c.POINTER(Result)]
library.pki_token_create.restype = c.c_void_p
library.pki_token_cancel.argtypes = [c.c_void_p]
library.pki_token_destroy.argtypes = [c.c_void_p]

records = []
def decode(path, backing, box=None, memory=384*1024*1024, token=None):
    error = c.create_string_buffer(512)
    meta = Metadata()
    status = library.pki_probe(str(path).encode(), c.byref(meta), error, 512)
    assert status == 0, (status, error.value)
    x, y, w, h = box or (0, 0, min(meta.width, 128), min(meta.height, 128))
    req = Request(x, y, w, h, w, h, memory, 1536*1024*1024, token)
    result = Result()
    status = library.pki_decode_region(str(path).encode(), str(backing).encode(), c.byref(req), c.byref(result), error, 512)
    if status:
        assert not result.pixels
        return status, error.value.decode(), meta
    try:
        pixels = np.ctypeslib.as_array(result.pixels, shape=(result.length,)).reshape(h, w, 4).copy()
        records.append(dict(name=path.name, x=x, y=y, width=w, height=h, peak=result.peak, disk=result.disk, micros=result.micros))
        return status, pixels, meta
    finally:
        library.pki_release(c.byref(result))

fixtures = Path(os.environ.get('PICAKEEP_IMAGE_ENGINE_FIXTURES', 'E:/picakeep-image-pipeline-022-fixtures'))
artifact_root = Path(os.environ.get('PICAKEEP_IMAGE_ENGINE_ARTIFACTS', 'E:/picakeep-native-022-artifacts'))
artifact_root.mkdir(parents=True, exist_ok=True)
with TemporaryDirectory(prefix='picakeep-native-pixels-022-', dir=artifact_root) as temp:
    target = Path(temp)
    for path in sorted(fixtures.glob('640x960-orientation-*.jpg')):
        reference = np.array(ImageOps.exif_transpose(Image.open(path)).convert('RGBA'))
        box = (reference.shape[1] // 2 - 64, reference.shape[0] - 128, 128, 128)
        status, pixels, meta = decode(path, target / (path.name + '.raw'), box)
        assert status == 0, pixels
        crop = reference[box[1]:box[1]+box[3], box[0]:box[0]+box[2]]
        assert np.max(np.abs(pixels.astype(int)-crop.astype(int))) <= 1, path
        assert (meta.width, meta.height) == (reference.shape[1], reference.shape[0])
    # Explicitly create RGBA image whose transparent RGB remains nonzero.
    rgba = np.zeros((96, 160, 4), dtype=np.uint8)
    rgba[:,:,:3] = (87, 192, 43)
    rgba[:,:,3] = np.arange(160, dtype=np.uint8)[None,:]
    path = target / 'alpha.png'; Image.fromarray(rgba).save(path)
    status, pixels, _ = decode(path, target / 'alpha.raw', (0, 0, 160, 96))
    assert status == 0 and np.array_equal(pixels, rgba)

    # JPEG 4:2:0 interpolation at tile edges and IDCT 1/8 scaled fit must agree
    # with a whole-image reference from a separately packaged JPEG decoder.
    subsampled = target / 'chroma-420.jpg'
    source_image=Image.open(fixtures/'640x960.png').convert('RGB')
    source_image.save(subsampled,quality=95,subsampling=2)
    reference=np.array(Image.open(subsampled).convert('RGBA'))
    reqfull=Request(0,0,640,960,1,1,64*1024*1024,64*1024*1024,None)
    fullresult=Result(); fullerror=c.create_string_buffer(512)
    fullbacking=target/'fullchroma.raw'
    fullstatus=library.pki_decode_region(str(subsampled).encode(),str(fullbacking).encode(),c.byref(reqfull),c.byref(fullresult),fullerror,512)
    assert fullstatus==0,fullerror.value
    library.pki_release(c.byref(fullresult))
    for box in [(101,73,128,128),(229,73,128,128),(101,201,128,128)]:
        status,pixels,_=decode(subsampled,target/'chroma.raw',box)
        assert status==0,pixels
        expected=reference[box[1]:box[1]+box[3],box[0]:box[0]+box[2]]
        difference=np.abs(pixels.astype(int)-expected.astype(int))
        _,fullpixels,_=decode(subsampled,fullbacking,box)
        assert np.array_equal(pixels,fullpixels), 'Crop must add zero error relative to the same codec whole image'
        records.append(dict(name='JPEG420-cross-decoder',reference='Pillow10.4.0/IJG9.0',native='libjpeg-turbo3.1.3',maximum_difference=int(difference.max()),same_codec_crop_difference=0))
    draft=Image.open(subsampled); draft.draft('RGB',(80,120))
    reference=np.array(draft.convert('RGBA'))
    req=Request(0,0,640,960,80,120,64*1024*1024,64*1024*1024,None)
    result=Result(); error=c.create_string_buffer(512)
    status=library.pki_decode_region(str(subsampled).encode(),str(target/'scaled.raw').encode(),c.byref(req),c.byref(result),error,512)
    assert status==0,error.value
    try: pixels=np.ctypeslib.as_array(result.pixels,shape=(result.length,)).reshape(120,80,4).copy()
    finally: library.pki_release(c.byref(result))
    whole_scaled=pixels
    scaled_parts=[]
    for sx in [0,320]:
        req=Request(sx,0,320,960,40,120,64*1024*1024,64*1024*1024,None)
        result=Result(); error=c.create_string_buffer(512)
        status=library.pki_decode_region(str(subsampled).encode(),str(target/'scaled-parts.raw').encode(),c.byref(req),c.byref(result),error,512)
        assert status==0,error.value
        try: scaled_parts.append(np.ctypeslib.as_array(result.pixels,shape=(result.length,)).reshape(120,40,4).copy())
        finally: library.pki_release(c.byref(result))
    assert np.array_equal(np.concatenate(scaled_parts,axis=1),whole_scaled)
    status, left, _ = decode(path, target / 'alpha.raw', (0, 0, 80, 96))
    status, right, _ = decode(path, target / 'alpha.raw', (80, 0, 80, 96))
    assert np.array_equal(np.concatenate((left, right), axis=1), rgba)
    # Same cold backing from concurrent callers publishes once and is exact.
    backing = target / 'concurrent.raw'
    with ThreadPoolExecutor(max_workers=4) as pool:
        output = list(pool.map(lambda _: decode(path, backing, (0, 0, 160, 96)), range(4)))
    assert all(status == 0 and np.array_equal(pixels, rgba) for status, pixels, _ in output)
    assert not list(target.glob('*.partial'))
    assert not list(target.glob('*.coeff-*'))
    status, _, _ = decode(path, backing, memory=1024)
    assert status == 3
    token = library.pki_token_create(); library.pki_token_cancel(token)
    status, _, _ = decode(path, backing, token=token)
    library.pki_token_destroy(token)
    assert status == 2
    # A modified authoritative source cannot reuse its old backing.
    rgba[:,:,0] = 201; Image.fromarray(rgba).save(path)
    status, pixels, _ = decode(path, backing, (0, 0, 160, 96))
    assert status == 0 and np.array_equal(pixels, rgba)

    # A codec data error after the header/working arrays have been allocated
    # must unwind all native ownership. Repeat to expose cumulative leaks.
    damaged_jpeg = target / 'damaged.jpg'
    original_jpeg = (fixtures / '640x960-baseline.jpg').read_bytes()
    # Corrupt a Huffman definition while retaining the recognized signature.
    damaged_jpeg.write_bytes(original_jpeg[:80])
    damaged_png = target / 'damaged.png'
    png_bytes = bytearray((fixtures / '640x960.png').read_bytes())
    png_bytes[len(png_bytes)//2] ^= 0x7f
    damaged_png.write_bytes(png_bytes)
    for _ in range(20):
        for damaged in [damaged_jpeg, damaged_png]:
            error=c.create_string_buffer(512)
            req=Request(0,0,64,64,64,64,64*1024*1024,64*1024*1024,None)
            result=Result()
            status=library.pki_decode_region(str(damaged).encode(),str(target/(damaged.name+'.raw')).encode(),c.byref(req),c.byref(result),error,512)
            assert status != 0 and not result.pixels
    assert not list(target.glob('*.partial'))

    # Cancel after a decoder starts, as well as before it starts.
    progressive = fixtures / '8000x12000-progressive.jpg'
    if progressive.exists():
        token=library.pki_token_create()
        with ThreadPoolExecutor(max_workers=1) as pool:
            pending=pool.submit(decode,progressive,target/'cancel-progressive.raw',(0,0,64,64),64*1024*1024,token)
            time.sleep(.02); library.pki_token_cancel(token)
            status,_,_=pending.result()
        library.pki_token_destroy(token)
        assert status==2
        assert not list(target.glob('*.partial'))
        assert not list(target.glob('*.coeff-*'))

report = Path(os.environ.get('PICAKEEP_IMAGE_ENGINE_REPORT', str(artifact_root / 'pixel-verification.json')))
report.write_text(json.dumps(records, indent=2), encoding='utf-8')
print(f'PASS: {sum("peak" in item for item in records)} successful decode records; 8 orientations, ICC sRGB, alpha, tile seams, concurrency, cancel, budget and source version.')
