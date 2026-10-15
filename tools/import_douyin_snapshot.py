"""Import own-profile metadata from a saved native UIA snapshot, never fetch a website."""
import argparse
import json
import re
import sys
from pathlib import Path
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from sync import Ledger


def own_notes(snapshot, account_id, account_name):
    nodes = snapshot['Nodes']
    documents = [urlparse(n.get('Value') or '') for n in nodes if n['Type'] == 'ControlType.Document']
    if not any(d.hostname in ('www.douyin.com', 'douyin.com') and d.path == '/user/self' for d in documents):
        raise ValueError('Expected the logged-in own Douyin profile document')
    texts = {n['Name'] for n in nodes if n['Type'] == 'ControlType.Text'}
    if account_id not in texts or account_name not in texts or '抖音号：' not in texts:
        raise ValueError('Own profile account does not match the configured source')
    groups = []
    current = None
    for node in nodes:
        if node['Type'] == 'ControlType.ListItem':
            current = []
            groups.append(current)
        if current is not None:
            current.append(node)
    notes = {}
    for group in groups:
        link = next((n for n in group if n['Type'] == 'ControlType.Hyperlink' and
                     re.fullmatch(r'https://www\.douyin\.com/video/\d{10,30}', n.get('Value') or '')), None)
        caption = next((n['Name'][len(account_name)+1:] for n in group
                        if n['Type'] == 'ControlType.Image' and n['Name'].startswith(account_name+'：')), None)
        if not link or not caption:
            continue
        video_id = link['Value'].rsplit('/', 1)[-1]
        notes[video_id] = {'note_id': video_id, 'source_platform': 'douyin', 'source_id': video_id,
                           'title': caption, 'url': link['Value'],
                           'pinned': any('置顶' in n['Name'] for n in group),
                           'media_status': 'metadata_only', 'latest_confirmed': False}
    if not notes:
        raise ValueError('No own video cards were found; no baseline was changed')
    return list(notes.values())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('snapshot', type=Path)
    parser.add_argument('--root', type=Path, default=ROOT)
    args = parser.parse_args()
    config = json.loads((args.root/'config.local.json').read_text(encoding='utf-8-sig'))
    source = config['source']
    if source['platform'] != 'douyin':
        raise ValueError('Douyin must be the configured read-only source')
    snapshot = json.loads(args.snapshot.read_text(encoding='utf-8-sig'))
    notes = own_notes(snapshot, source['account_id'], source['account_name'])
    ledger = Ledger(args.root/'data/sync.sqlite3')
    try:
        for note in notes:
            note['ledger_key'] = ledger.observe(note, baseline=True)
    finally:
        ledger.close()
    result = {'source_platform': 'douyin', 'account_id': source['account_id'], 'notes': notes,
              'loaded_count': len(notes), 'complete_history': False, 'automatic_backfill': False,
              'cover_and_video_downloaded': False, 'snapshot': str(args.snapshot.resolve())}
    output = args.root/'data/douyin/metadata-baseline.json'
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(result, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
    print(json.dumps({k: result[k] for k in ('loaded_count', 'complete_history', 'automatic_backfill', 'cover_and_video_downloaded')}, ensure_ascii=False))


if __name__ == '__main__':
    main()
