import tempfile
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


if __name__ == '__main__':
    unittest.main()
