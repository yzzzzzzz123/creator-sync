"""Create a browser-compatible H.264 copy of locally RPA-acquired media, retaining AAC audio."""
import argparse
import hashlib
import json
import os
import shutil
import subprocess
from pathlib import Path

from verify_media import verify

ROOT=Path(__file__).resolve().parents[1]


def run(binary,arguments,timeout=120):
    result=subprocess.run([str(binary),'-nostdin','-hide_banner',*arguments],stdin=subprocess.DEVNULL,
                          capture_output=True,creationflags=subprocess.CREATE_NO_WINDOW if os.name=='nt' else 0,
                          timeout=timeout)
    if result.returncode:raise ValueError(result.stderr.decode('utf-8',errors='replace')[-3000:])
    return result.stdout


def audio_hash(binary,path):
    return run(binary,['-v','error','-i',str(path),'-map','0:a:0','-c:a','copy','-f','hash','-hash','sha256','-']).decode().strip()


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('source',type=Path)
    args=parser.parse_args();source=args.source.resolve();output=source.with_name('video-h264.mp4')
    if output.exists():raise ValueError('Compatible copy already exists; verify and reuse it')
    source_hash=hashlib.sha256(source.read_bytes()).hexdigest()
    candidates=list((ROOT/'artifacts/vendor/imageio_ffmpeg/binaries').glob('ffmpeg-*.exe'))
    binary=shutil.which('ffmpeg') or (candidates[0] if len(candidates)==1 else None)
    if not binary:raise ValueError('Install imageio-ffmpeg into artifacts/vendor or provide ffmpeg on PATH')
    run(binary,['-v','error','-n','-i',str(source),'-map','0:v:0','-map','0:a:0','-c:v','libx264',
                '-preset','fast','-crf','18','-pix_fmt','yuv420p','-c:a','copy','-movflags','+faststart',str(output)])
    verified=verify(output)
    if verified['status']!='verified':raise ValueError('Compatible copy did not decode completely')
    # Decode the audio and compare copied encoded packets, preserving the actual piano recording.
    run(binary,['-v','error','-i',str(output),'-map','0:a:0','-f','null','-'])
    before=audio_hash(binary,source);after=audio_hash(binary,output)
    if before!=after:raise ValueError('Copied piano audio changed')
    if hashlib.sha256(source.read_bytes()).hexdigest()!=source_hash:raise ValueError('Original source changed')
    verified.update(source_sha256=source_hash,audio_bitstream_unchanged=True,audio_stream_hash=after,
                    method='Local H.264 compatibility transcode; AAC audio copied, source retained')
    (output.parent/'video-h264-verification.json').write_text(json.dumps(verified,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    check_path=ROOT/'data/douyin/acquisition-check.json'
    check=json.loads(check_path.read_text(encoding='utf-8-sig'))
    if check['Video']['sha256']!=source_hash:raise ValueError('Source does not match active RPA batch')
    check['UploadVideo']=verified
    temporary=check_path.with_suffix('.json.tmp')
    temporary.write_text(json.dumps(check,ensure_ascii=False,indent=2)+'\n',encoding='utf-8');temporary.replace(check_path)
    print(json.dumps({'compatible_file':str(output),'codec':'H.264','frames':verified['decoded_frames'],
                      'audio_bitstream_unchanged':True,'original_retained':True},ensure_ascii=False))


if __name__=='__main__':main()
