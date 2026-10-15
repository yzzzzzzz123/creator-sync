"""Bind native GUI evidence and register browser-saved own Douyin assets, offline only."""
import argparse
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import parse_qs, urlparse

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from sync import Ledger, sha256
from tools.import_douyin_snapshot import own_notes


def read(path):
    return json.loads(Path(path).read_text(encoding='utf-8-sig'))


def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + '.tmp')
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    temporary.replace(path)


def media_url(url, source_id):
    parsed = urlparse(url)
    trusted = re.fullmatch(r'(?:[a-z0-9-]+\.)*douyinvod\.com|v\d+-dy-[a-z0-9-]+\.zjcdn\.com', parsed.hostname or '')
    if (not re.fullmatch(r'\d{10,30}', source_id) or parsed.scheme != 'https' or not trusted
            or parsed.username or parsed.password or parsed.port not in (None, 443)
            or parse_qs(parsed.query).get('__vid') != [source_id]):
        raise ValueError('Media must be a trusted HTTPS playback URL for this exact source ID')
    return parsed


def validate_binding(snapshot, binding, *, fresh=False):
    capture = snapshot.get('Binding') or snapshot.get('Window', {})
    if capture.get('WindowHandle', capture.get('Handle')) != binding['WindowHandle'] or capture.get('ProcessId') != binding['ProcessId']:
        raise ValueError('Snapshot belongs to another Chrome window/process')
    at = datetime.fromisoformat(snapshot['At'].replace('Z', '+00:00'))
    started = datetime.fromisoformat(binding['ProcessStartUtc'].replace('Z', '+00:00'))
    age = (datetime.now(timezone.utc) - at).total_seconds()
    if at < started or age < -60 or (fresh and age > 900):
        raise ValueError('Stale or future snapshot; capture the current source again')


def source_card(profile, account, source_id):
    notes = own_notes(profile, account['account_id'], account['account_name'])
    note = next((note for note in notes if note['source_id'] == source_id), None)
    if not note:
        raise ValueError('This exact source ID is absent from the verified own profile')
    return note


def bind(root, source_id, profile_path, network_path, media_path):
    account = read(root/'config.local.json')['source']
    if account.get('platform') != 'douyin' or not account.get('read_only'):
        raise ValueError('Expected the configured read-only Douyin source')
    binding = read(root/'data/browser-binding.json')
    snapshots = [read(path) for path in (profile_path, network_path, media_path)]
    for snapshot in snapshots:
        validate_binding(snapshot, binding, fresh=True)
    profile, network, media = snapshots
    note = source_card(profile, account, source_id)
    documents = [n.get('Value') for n in network['Nodes'] if n['Type'] == 'ControlType.Document']
    if note['url'] not in documents or not any((url or '').startswith('devtools://') for url in documents):
        raise ValueError('Expected visible DevTools and the exact source document together')
    if not any(n.get('Class') == 'name-column' and re.search(r'(?:[?&])__vid=' + source_id + r'(?:&|$)', n['Name']) for n in network['Nodes']):
        raise ValueError('No Media request row for this source ID')
    documents = [n.get('Value') for n in media['Nodes'] if n['Type'] == 'ControlType.Document']
    if len(documents) != 1:
        raise ValueError('Expected one standalone browser media document')
    parsed = media_url(documents[0], source_id)
    active = root/'data/skill/active-run.json'
    if active.exists():
        run = read(active)
        if run.get('note_id') not in (None, 'douyin:' + source_id) and run.get('next_step') != 'complete':
            raise ValueError('An unfinished batch is bound to another source')
    manifest = {'SourceId': source_id, 'SourceUrl': note['url'], 'SourceTitle': note['title'],
                'AccountId': account['account_id'], 'MediaUrl': documents[0], 'Host': parsed.hostname,
                'At': datetime.now(timezone.utc).isoformat(),
                'Method': 'Native UIA: visible DevTools Network Media -> Open in new tab',
                'Evidence': [str(Path(path).resolve()) for path in (profile_path, network_path, media_path)]}
    write(root/'data/douyin/active-media.json', manifest)
    # Never print the signed playback URL.
    return {'source_id': source_id, 'host': parsed.hostname, 'bound': True}


def saved_claim(root, source_id, purpose, path):
    candidates = [root/f'data/douyin/claims/{source_id}/{purpose.lower()}-save-intent.json']
    candidates.append(root/f'data/douyin/active-{purpose.lower()}-save-intent.json')
    if purpose == 'Video':
        candidates.append(root/'data/douyin/active-media-save-intent.json')
    for candidate in candidates:
        if candidate.exists():
            claim = read(candidate)
            if (claim.get('SourceId') == source_id and claim.get('Purpose', 'Video') == purpose
                    and Path(claim['Path']).resolve() == path.resolve()):
                return str(candidate.resolve())
    raise ValueError('No native browser save intent matches this source and asset path')


def finish(root, video, cover):
    from PIL import Image
    manifest = read(root/'data/douyin/active-media.json')
    source_id = manifest['SourceId']
    media_url(manifest['MediaUrl'], source_id)
    if manifest['SourceUrl'] != f'https://www.douyin.com/video/{source_id}':
        raise ValueError('Source URL and media ID do not match')
    for path in (video, cover):
        if not path.resolve().is_relative_to((root/'data').resolve()):
            raise ValueError('Assets must remain inside project data')
    claims = [saved_claim(root, source_id, purpose, path) for purpose, path in (('Video', video), ('Cover', cover))]
    report = read(video.with_name(video.stem + '-verification.json'))
    if (report.get('status') != 'verified' or report.get('sha256') != sha256(video)
            or report.get('decoded_frames', 0) <= 0 or report.get('decoded_frames') != report.get('declared_frames')
            or Path(report['path']).resolve() != video.resolve()):
        raise ValueError('Full video decode/hash verification is required')
    with Image.open(cover) as image:
        dimensions, image_format = image.size, image.format
        image.verify()
    title = manifest.get('SourceTitle')
    if not title:  # Recover the original verified POC without replacing its claims.
        notes = read(root/'data/douyin/metadata-baseline.json')['notes']
        title = next(note['title'] for note in notes if note['source_id'] == source_id)
    ledger = Ledger(root/'data/sync.sqlite3')
    try:
        key = ledger.observe({'note_id': source_id, 'source_platform': 'douyin', 'title': title,
                              'url': manifest['SourceUrl'], 'video_path': str(video.resolve()),
                              'cover_path': str(cover.resolve()), 'video_sha256': report['sha256']})
    finally:
        ledger.close()
    check_path = root/'data/douyin/acquisition-check.json'
    previous = read(check_path) if check_path.exists() else {}
    result = previous if previous.get('SourceId') == source_id and previous.get('Video', {}).get('sha256') == report['sha256'] else {}
    result.update(Status='rpa_assets_verified', SourceId=source_id, LedgerKey=key, Title=title,
                  SourceUrl=manifest['SourceUrl'], Video=report,
                  Cover={'Path': str(cover.resolve()), 'Format': image_format, 'Dimensions': dimensions, 'Sha256': sha256(cover)},
                  Method='Native Chrome GUI playback Save As and own-card image Save As',
                  CookieExported=False, CDPUsed=False, JavaScriptInjected=False, PrivateApiCalled=False,
                  OriginalFolderRequired=False, At=datetime.now(timezone.utc).isoformat(),
                  Evidence=manifest['Evidence'] + claims,
                  QualityNote='Downloaded web playback representation, not the original master')
    write(check_path, result)
    write(video.parent/'source.json', result)
    return {'source_key': key, 'status': result['Status'], 'frames': report['decoded_frames'], 'cover_dimensions': dimensions}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=ROOT)
    sub = parser.add_subparsers(dest='action', required=True)
    binding = sub.add_parser('bind')
    for name in ('source-id', 'profile-snapshot', 'network-snapshot', 'media-snapshot'):
        binding.add_argument('--' + name, required=True, type=str if name == 'source-id' else Path)
    registration = sub.add_parser('finish')
    registration.add_argument('--video', type=Path, required=True)
    registration.add_argument('--cover', type=Path, required=True)
    args = parser.parse_args()
    if (args.root/'data/STOP').exists():
        raise ValueError('User STOP file exists')
    result = (bind(args.root, args.source_id, args.profile_snapshot, args.network_snapshot, args.media_snapshot)
              if args.action == 'bind' else finish(args.root, args.video, args.cover))
    print(json.dumps(result, ensure_ascii=False))


if __name__ == '__main__':
    main()
