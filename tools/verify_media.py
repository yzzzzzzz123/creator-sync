"""Verify a locally saved MP4 and extract clean reference frames; never fetch media."""
import argparse
import hashlib
import json
import struct
from pathlib import Path


def boxes(data):
    offset=0
    while offset+8<=len(data):
        size,kind=struct.unpack_from('>I4s',data,offset);header=8
        if size==1:
            if offset+16>len(data):raise ValueError('Incomplete extended MP4 header')
            size=struct.unpack_from('>Q',data,offset+8)[0];header=16
        if size==0:size=len(data)-offset
        if size<header or offset+size>len(data):raise ValueError('Incomplete MP4 box')
        yield kind.decode('ascii',errors='replace'),data[offset+header:offset+size]
        offset+=size
    if offset!=len(data):raise ValueError('Unparsed trailing MP4 bytes')


def child(data,name):
    return next(payload for kind,payload in boxes(data) if kind==name)


def verify(path,expected_seconds=None):
    import cv2
    blob=path.read_bytes();movie=child(blob,'moov');tracks=[]
    for kind,payload in boxes(movie):
        if kind!='trak':continue
        mdia=child(payload,'mdia');handler=child(mdia,'hdlr')[8:12].decode('ascii')
        mdhd=child(mdia,'mdhd');offset=20 if mdhd[0]==1 else 12
        scale=struct.unpack_from('>I',mdhd,offset)[0]
        duration=struct.unpack_from('>Q' if mdhd[0]==1 else '>I',mdhd,offset+4)[0]/scale
        stsd=child(child(child(mdia,'minf'),'stbl'),'stsd')
        tracks.append({'handler':handler,'codecs':[name for name,_ in boxes(stsd[8:])],'seconds':duration})
    video=next(t for t in tracks if t['handler']=='vide')
    audio=next(t for t in tracks if t['handler']=='soun')
    if abs(video['seconds']-audio['seconds'])>1:raise ValueError('Audio and video duration mismatch')
    if expected_seconds is not None and abs(video['seconds']-expected_seconds)>1:raise ValueError('Duration does not match the source page')
    capture=cv2.VideoCapture(str(path))
    details={'bytes':len(blob),'sha256':hashlib.sha256(blob).hexdigest(),'tracks':tracks,'path':str(path.resolve())}
    if not capture.isOpened():
        details['status']='codec_not_decoded';return details
    width=int(capture.get(cv2.CAP_PROP_FRAME_WIDTH));height=int(capture.get(cv2.CAP_PROP_FRAME_HEIGHT))
    declared=int(capture.get(cv2.CAP_PROP_FRAME_COUNT));fps=capture.get(cv2.CAP_PROP_FPS);count=0
    frames=path.parent/'frames';frames.mkdir(exist_ok=True)
    while True:
        ok,frame=capture.read()
        if not ok:break
        if frame.shape[:2]!=(height,width):raise ValueError('Frame dimensions changed')
        if count in (0,declared//2,declared-1):
            if frame.std()<5:raise ValueError('Blank reference frame')
            cv2.imwrite(str(frames/f'frame-{count:04d}.jpg'),frame)
        count+=1
    capture.release()
    details.update(width=width,height=height,fps=fps,declared_frames=declared,decoded_frames=count,
                   status='verified' if count==declared and count>0 else 'incomplete_decode')
    return details


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('path',type=Path);parser.add_argument('--expected-seconds',type=float)
    args=parser.parse_args();result=verify(args.path,args.expected_seconds)
    output=args.path.parent/(args.path.stem+'-verification.json')
    output.write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(result,ensure_ascii=False))
    if result['status']!='verified':raise SystemExit(2)


if __name__=='__main__':main()
