"""One-time local migration; copies assets, never browser credentials or saved web pages."""
import argparse
import json
import shutil
import sys
from pathlib import Path
from urllib.parse import urlsplit

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT))
from sync import Ledger,sha256


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('poc_root',type=Path,help='windows-rpa-github/artifacts/work')
    args=p.parse_args()
    xhs=args.poc_root/'xhs-own-content-poc'
    yt=args.poc_root/'youtube-publish-poc-20261015'
    state=json.loads((yt/'state.json').read_text(encoding='utf-8-sig'))
    if state['Status']!='PublishedVerified' or not state['AnonymousPlaybackVerified']:
        raise ValueError('Expected verified YouTube receipt')
    ledger=Ledger(ROOT/'data'/'sync.sqlite3')
    try:
        notes=json.loads((xhs/'own-notes.json').read_text(encoding='utf-8-sig'))
        for item in notes:
            source=xhs/'samples'/item['note_id']
            dest=ROOT/'data'/'assets'/item['note_id']
            dest.mkdir(parents=True,exist_ok=True)
            shutil.copy2(source/'cover.webp',dest/'cover.webp')
            note={'note_id':item['note_id'],'title':item['title'],'url':item['note_url'],
                  'cover_path':str(dest/'cover.webp')}
            if (source/'video.mp4').is_file():
                shutil.copy2(source/'video.mp4',dest/'video.mp4')
                note.update(video_path=str(dest/'video.mp4'),video_sha256=sha256(dest/'video.mp4'))
            ledger.observe(note,baseline=True)
        note_id=state['SourceNoteId']
        if sha256(ROOT/'data'/'assets'/note_id/'video.mp4') != state['SourceSha256']:
            raise ValueError('Migrated source hash mismatch')
        dest=ROOT/'data'/'assets'/note_id
        for name in ('thumbnail.png','thumbnail-prompt.txt'):
            shutil.copy2(yt/name,dest/('youtube-'+name))
        ledger.prepare(note_id,'youtube',state['ChannelId'],state['Title'])
        ledger.record(note_id,'youtube',state['ChannelId'],'published',state['VideoId'],state['VideoUrl'],
                      {'imported_from':'youtube-single-poc','anonymous_playback_verified':True,
                       'public_verified_at':state['PublicVerifiedAt'],
                       'thumbnail_sha256':state['ThumbnailSha256']})
        receipt=ROOT/'data'/'receipts'/'youtube-existing'
        receipt.mkdir(parents=True,exist_ok=True)
        for name in ('result.json','public-final.png','public-final.json','published-backend.png'):
            if (yt/name).is_file():
                shutil.copy2(yt/name,receipt/name)
        for folder,names in ((xhs,('extract_saved.py','verify_video.py','Save-XhsPage.ps1','Interact-Xhs.ps1','README.md')),
                             (yt,('Rpa.ps1','Choose-Video.ps1','Publish-One.ps1','README.md'))):
            archive=ROOT/'data'/'legacy-poc'/folder.name
            archive.mkdir(parents=True,exist_ok=True)
            for name in names:
                if (folder/name).is_file():
                    shutil.copy2(folder/name,archive/name)
        config=json.loads((ROOT/'config.example.json').read_text(encoding='utf-8'))
        profile_path=urlsplit(notes[0]['note_url']).path.split('/')
        if profile_path[1:3] != ['user','profile']:
            raise ValueError('Expected own-profile note URL')
        config['source']['account_id']=profile_path[3]
        config['targets']['youtube']['account_id']=state['ChannelId']
        local=ROOT/'config.local.json'
        if not local.exists():
            local.write_text(json.dumps(config,ensure_ascii=False,indent=2),encoding='utf-8')
        print(json.dumps({'source_count':ledger.status()['source_count'],'youtube_imported':state['VideoUrl'],
                          'source_sha256_verified':True},ensure_ascii=False))
    finally:
        ledger.close()


if __name__=='__main__':
    main()
