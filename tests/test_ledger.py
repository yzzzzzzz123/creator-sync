import tempfile
import sqlite3
import unittest
from pathlib import Path
from sync import Ledger, sha256


class LedgerTest(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory()
        self.root=Path(self.tmp.name)
        self.video=self.root/'video.mp4'
        self.video.write_bytes(b'fixture media')
        self.path=self.root/'ledger.sqlite3'
        self.ledger=Ledger(self.path)
        self.note={'note_id':'a','title':'中文题目','url':'https://www.xiaohongshu.com/explore/a',
                   'video_path':str(self.video),'video_sha256':sha256(self.video)}
        self.ledger.observe(self.note)

    def tearDown(self):
        self.ledger.close()
        self.tmp.cleanup()

    def prepare(self,platform='youtube',account='owner'):
        return self.ledger.prepare('a',platform,account,'Title')

    def test_published_youtube_does_not_block_bilibili(self):
        self.prepare()
        self.ledger.record('a','youtube','owner','published','v','https://youtu.be/v',{'public':True})
        self.assertEqual(self.prepare()['status'],'published')
        self.assertEqual(self.prepare('bilibili')['status'],'ready')

    def test_crash_after_claim_never_replays(self):
        self.prepare()
        self.ledger.claim_submit('a','youtube','owner')
        self.ledger.close()
        self.ledger=Ledger(self.path)
        with self.assertRaises(ValueError):
            self.ledger.claim_submit('a','youtube','owner')
        self.assertEqual(self.prepare()['status'],'submitting')

    def test_same_bytes_under_new_source_id_deduplicate(self):
        self.prepare()
        self.ledger.observe(dict(self.note,note_id='b'))
        result=self.ledger.prepare('b','youtube','owner','Other title')
        self.assertEqual(result['note_id'],'a')
        self.assertEqual(len(self.ledger.status()['deliveries']),1)

    def test_changed_media_stops_before_claim(self):
        self.prepare()
        self.video.write_bytes(b'changed')
        with self.assertRaises(ValueError):
            self.ledger.claim_submit('a','youtube','owner')
        self.assertIsNone(self.ledger.get('a','youtube','owner')['intent_at'])

    def test_observation_preserves_assets_and_receipt(self):
        self.prepare()
        self.ledger.record('a','youtube','owner','published','v','https://youtu.be/v',{'verified':True})
        self.ledger.observe({'note_id':'a','title':'new','url':self.note['url']})
        self.assertEqual(self.prepare()['status'],'published')
        with self.assertRaises(ValueError):
            self.ledger.record('a','youtube','owner','published','different','https://youtu.be/other',{'verified':True})

    def test_separate_connection_cannot_claim_twice(self):
        self.prepare()
        second=Ledger(self.path)
        try:
            self.ledger.claim_submit('a','youtube','owner')
            with self.assertRaises(ValueError):
                second.claim_submit('a','youtube','owner')
        finally:
            second.close()

    def test_platform_ids_are_isolated_and_cross_source_hash_still_deduplicates(self):
        self.prepare()
        key=self.ledger.observe(dict(self.note,source_platform='douyin'))
        self.assertEqual(key,'douyin:a')
        self.assertEqual(self.ledger.status()['source_count'],2)
        self.assertEqual(self.ledger.prepare(key,'youtube','owner','Title')['note_id'],'a')

    def test_five_destinations_are_independent_and_douyin_cannot_be_target(self):
        key=self.ledger.observe(dict(self.note,source_platform='douyin'))
        for platform in ('xiaohongshu','bilibili','youtube','tiktok','instagram'):
            self.assertEqual(self.ledger.prepare(key,platform,'owner','Title')['status'],'ready')
        with self.assertRaises(ValueError):self.ledger.prepare(key,'douyin','owner','Title')
        with self.assertRaises(ValueError):self.ledger.prepare('a','xiaohongshu','owner','Title')
        with self.assertRaises(ValueError):self.ledger.prepare(key,'tiktok','SET_AFTER_LOGIN','Title')

    def test_migration_preserves_legacy_unknown_delivery_and_ids(self):
        path=self.root/'legacy.sqlite3'
        db=sqlite3.connect(path)
        db.executescript('''CREATE TABLE sources(note_id TEXT PRIMARY KEY,title TEXT NOT NULL,url TEXT NOT NULL,
          cover_path TEXT,video_path TEXT,video_sha256 TEXT,first_seen TEXT NOT NULL,baseline INTEGER NOT NULL DEFAULT 1);
          CREATE TABLE deliveries(note_id TEXT NOT NULL REFERENCES sources(note_id),platform TEXT NOT NULL,
          account_id TEXT NOT NULL,status TEXT NOT NULL,title TEXT NOT NULL,video_sha256 TEXT NOT NULL,
          target_id TEXT,target_url TEXT,intent_at TEXT,updated_at TEXT NOT NULL,evidence TEXT NOT NULL DEFAULT '{}',
          PRIMARY KEY(note_id,platform,account_id),UNIQUE(platform,account_id,video_sha256));
          INSERT INTO sources(note_id,title,url,first_seen) VALUES('old','Title','https://example.test','t');
          INSERT INTO deliveries(note_id,platform,account_id,status,title,video_sha256,intent_at,updated_at)
          VALUES('old','youtube','owner','submitting','Title','h','original-intent','t');''')
        db.close()
        migrated=Ledger(path)
        try:
            row=migrated.db.execute('SELECT * FROM sources').fetchone()
            self.assertEqual((row['note_id'],row['source_platform'],row['source_id']),('old','xiaohongshu','old'))
            self.assertEqual(migrated.get('old','youtube','owner')['intent_at'],'original-intent')
            with self.assertRaises(ValueError):migrated.claim_submit('old','youtube','owner')
        finally:migrated.close()


if __name__ == '__main__':
    unittest.main()
