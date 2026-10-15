"""Local source registry and per-account delivery ledger. No network/API calls."""
import argparse
import hashlib
import json
import sqlite3
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent
TARGET_PLATFORMS = ('xiaohongshu', 'bilibili', 'youtube', 'tiktok', 'instagram')
SOURCE_PLATFORMS = ('xiaohongshu', 'douyin')


def source_key(platform, source_id):
    if platform not in SOURCE_PLATFORMS or not source_id or ':' in source_id:
        raise ValueError('Known source platform and unprefixed source ID required')
    # Keep pre-existing Xiaohongshu receipts valid. All new Douyin IDs are namespaced.
    return source_id if platform == 'xiaohongshu' else f'{platform}:{source_id}'


def now():
    return datetime.now(timezone.utc).isoformat()


def sha256(path):
    with open(path, 'rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


class Ledger:
    def __init__(self, path):
        path = Path(path)
        path.parent.mkdir(parents=True, exist_ok=True)
        self.db = sqlite3.connect(path, timeout=10, isolation_level=None)
        self.db.row_factory = sqlite3.Row
        self.db.execute('PRAGMA journal_mode=WAL')
        self.db.execute('PRAGMA foreign_keys=ON')
        self.db.execute('PRAGMA synchronous=FULL')
        self.db.executescript('''
          CREATE TABLE IF NOT EXISTS sources (
            note_id TEXT PRIMARY KEY, title TEXT NOT NULL, url TEXT NOT NULL,
            cover_path TEXT, video_path TEXT, video_sha256 TEXT,
            first_seen TEXT NOT NULL, baseline INTEGER NOT NULL DEFAULT 1
          );
          CREATE TABLE IF NOT EXISTS deliveries (
            note_id TEXT NOT NULL REFERENCES sources(note_id), platform TEXT NOT NULL,
            account_id TEXT NOT NULL, status TEXT NOT NULL, title TEXT NOT NULL,
            video_sha256 TEXT NOT NULL, target_id TEXT, target_url TEXT,
            intent_at TEXT, updated_at TEXT NOT NULL, evidence TEXT NOT NULL DEFAULT '{}',
            PRIMARY KEY(note_id,platform,account_id),
            UNIQUE(platform,account_id,video_sha256)
          );
        ''')
        with self.transaction():
            columns = {r['name'] for r in self.db.execute('PRAGMA table_info(sources)')}
            if 'source_platform' not in columns:
                self.db.execute("ALTER TABLE sources ADD COLUMN source_platform TEXT NOT NULL DEFAULT 'xiaohongshu'")
            if 'source_id' not in columns:
                self.db.execute('ALTER TABLE sources ADD COLUMN source_id TEXT')
                self.db.execute('UPDATE sources SET source_id=note_id')
            self.db.execute('CREATE UNIQUE INDEX IF NOT EXISTS source_identity ON sources(source_platform,source_id)')

    def close(self):
        self.db.close()

    @contextmanager
    def transaction(self):
        self.db.execute('BEGIN IMMEDIATE')
        try:
            yield
        except BaseException:
            self.db.rollback()
            raise
        else:
            self.db.commit()

    def observe(self, note, baseline=True):
        # Observation must never erase a locally downloaded video or completed delivery.
        platform = note.get('source_platform', note.get('platform', 'xiaohongshu'))
        source_id = note.get('source_id', note['note_id'])
        key = source_key(platform, source_id)
        self.db.execute('''INSERT INTO sources
          (note_id,title,url,cover_path,video_path,video_sha256,first_seen,baseline,source_platform,source_id)
          VALUES (?,?,?,?,?,?,?,?,?,?) ON CONFLICT(note_id) DO UPDATE SET
          title=excluded.title,url=excluded.url,
          cover_path=COALESCE(excluded.cover_path,sources.cover_path),
          video_path=COALESCE(excluded.video_path,sources.video_path),
          video_sha256=COALESCE(excluded.video_sha256,sources.video_sha256)''',
          (key,note['title'],note['url'],note.get('cover_path'),
           note.get('video_path'),note.get('video_sha256'),now(),int(baseline),platform,source_id))
        return key

    def prepare(self, note_id, platform, account_id, title):
        if platform not in TARGET_PLATFORMS or not account_id or account_id.startswith('SET_'):
            raise ValueError('Known platform and bound target account required')
        with self.transaction():
            source = self.db.execute('SELECT * FROM sources WHERE note_id=?',(note_id,)).fetchone()
            if not source or not source['video_sha256'] or not source['video_path']:
                raise ValueError('Verified local video required')
            if platform == source['source_platform']:
                raise ValueError('The source platform is read-only; self-publication is forbidden')
            if sha256(source['video_path']) != source['video_sha256']:
                raise ValueError('Source file changed')
            existing = self.db.execute('''SELECT * FROM deliveries WHERE platform=? AND
              account_id=? AND (note_id=? OR video_sha256=?)''',
              (platform,account_id,note_id,source['video_sha256'])).fetchone()
            if existing:
                return dict(existing)
            self.db.execute('''INSERT INTO deliveries
              (note_id,platform,account_id,status,title,video_sha256,updated_at)
              VALUES (?,?,?,'ready',?,?,?)''',
              (note_id,platform,account_id,title,source['video_sha256'],now()))
        return self.get(note_id,platform,account_id)

    def get(self,note_id,platform,account_id):
        row=self.db.execute('SELECT * FROM deliveries WHERE note_id=? AND platform=? AND account_id=?',
                            (note_id,platform,account_id)).fetchone()
        return dict(row) if row else None

    def claim_submit(self,note_id,platform,account_id):
        # Durable one-time claim, committed BEFORE any UI click; crashes require reconciliation.
        with self.transaction():
            row=self.get(note_id,platform,account_id)
            if not row or row['status'] != 'ready' or row['intent_at']:
                raise ValueError('Submission already claimed or delivery not ready; reconcile, do not retry')
            source=self.db.execute('SELECT * FROM sources WHERE note_id=?',(note_id,)).fetchone()
            if sha256(source['video_path']) != row['video_sha256']:
                raise ValueError('Source file changed')
            self.db.execute('''UPDATE deliveries SET status='submitting',intent_at=?,updated_at=?
              WHERE note_id=? AND platform=? AND account_id=?''',
              (now(),now(),note_id,platform,account_id))
        return self.get(note_id,platform,account_id)

    def record(self,note_id,platform,account_id,status,target_id,target_url,evidence):
        if status not in ('submitted','processing','published','existing') or not target_id or not target_url or not evidence:
            raise ValueError('Platform result and evidence required')
        with self.transaction():
            row=self.get(note_id,platform,account_id)
            if not row:
                raise ValueError('Prepare delivery before recording')
            if row['target_id'] and row['target_id'] != target_id:
                raise ValueError('Target identity cannot change')
            if row['status'] in ('published','existing') and status not in ('published','existing'):
                raise ValueError('Cannot downgrade verified receipt')
            self.db.execute('''UPDATE deliveries SET status=?,target_id=?,target_url=?,evidence=?,updated_at=?
              WHERE note_id=? AND platform=? AND account_id=?''',
              (status,target_id,target_url,json.dumps(evidence,ensure_ascii=False),now(),note_id,platform,account_id))

    def status(self):
        return {'source_count':self.db.execute('SELECT count(*) FROM sources').fetchone()[0],
                'deliveries':[dict(row) for row in self.db.execute('SELECT * FROM deliveries ORDER BY updated_at')]}


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--db',type=Path,default=ROOT/'data'/'sync.sqlite3')
    parser.add_argument('action',choices=['status','plan'])
    args=parser.parse_args()
    ledger=Ledger(args.db)
    try:
        status=ledger.status()
        if args.action == 'plan':
            # Explicitly prepared candidates only: never mass backfill observed profile cards.
            status={'ready':[d for d in status['deliveries'] if d['status']=='ready'],
                    'needs_reconciliation':[d for d in status['deliveries'] if d['status'] in ('submitting','submitted','processing')],
                    'automatic_scheduler':False,'max_posts_per_run':1}
        print(json.dumps(status,ensure_ascii=False,indent=2))
    finally:
        ledger.close()


if __name__ == '__main__':
    main()
