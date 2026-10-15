import copy
import struct
import json
import tempfile
import unittest
from pathlib import Path
from tools.rpa_source import media_url, source_card, validate_binding, saved_claim
from tools.verify_media import boxes


class SourceEvidenceTest(unittest.TestCase):
    def test_media_requires_exact_id_and_known_host(self):
        source_id = '12345678901'
        for host in ('v1.douyinvod.com', 'v5-dy-ov-experiment.zjcdn.com'):
            self.assertEqual(media_url(f'https://{host}/video/a?__vid={source_id}', source_id).hostname, host)
        for url in ('https://douyinvod.com.example.org/video?__vid=12345678901',
                    'https://v5-other.zjcdn.com/video?__vid=12345678901',
                    'https://v1.douyinvod.com/video?__vid=12345678902',
                    'https://v1.douyinvod.com/video?__vid=12345678901&__vid=12345678902',
                    'https://user:secret@v1.douyinvod.com/video?__vid=12345678901'):
            with self.subTest(url=url), self.assertRaises(ValueError):
                media_url(url, source_id)

    def test_own_profile_must_contain_exact_candidate(self):
        profile = {'Nodes': [
            {'Type': 'ControlType.Document', 'Name': '', 'Value': 'https://www.douyin.com/user/self'},
            *({'Type': 'ControlType.Text', 'Name': text} for text in ('owner', 'Yu', '抖音号：')),
            {'Type': 'ControlType.ListItem', 'Name': ''},
            {'Type': 'ControlType.Hyperlink', 'Name': '', 'Value': 'https://www.douyin.com/video/12345678902'},
            {'Type': 'ControlType.Image', 'Name': 'Yu：新标题 #钢琴'}]}
        account = {'account_id': 'owner', 'account_name': 'Yu'}
        self.assertEqual(source_card(profile, account, '12345678902')['title'], '新标题 #钢琴')
        with self.assertRaises(ValueError):
            source_card(profile, account, '12345678903')
        with self.assertRaises(ValueError):
            source_card(profile, dict(account, account_id='another'), '12345678902')

    def test_snapshot_from_previous_process_or_other_window_is_rejected(self):
        binding = {'WindowHandle': 123, 'ProcessId': 7, 'ProcessStartUtc': '2026-01-01T10:00:00Z'}
        snapshot = {'Window': {'Handle': 123, 'ProcessId': 7}, 'At': '2026-01-01T10:01:00Z'}
        validate_binding(snapshot, binding)
        wrong = copy.deepcopy(snapshot); wrong['Window']['Handle'] = 999
        with self.assertRaises(ValueError): validate_binding(wrong, binding)
        old = dict(snapshot, At='2026-01-01T09:59:00Z')
        with self.assertRaises(ValueError): validate_binding(old, binding)

    def test_truncated_mp4_box_is_not_accepted_as_a_download(self):
        complete = struct.pack('>I4s', 12, b'mdat') + b'1234'
        self.assertEqual(list(boxes(complete)), [('mdat', b'1234')])
        for incomplete in (complete[:-1], complete + b'bad', struct.pack('>I4s', 1, b'mdat')):
            with self.assertRaises(ValueError): list(boxes(incomplete))

    def test_old_global_save_claim_cannot_bind_a_different_source(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); media = root/'data/douyin'
            media.mkdir(parents=True); video = root/'data/video.mp4'
            claim = {'SourceId':'12345678901', 'Path':str(video)}
            (media/'active-media-save-intent.json').write_text(json.dumps(claim), encoding='utf-8')
            self.assertTrue(saved_claim(root,'12345678901','Video',video).endswith('active-media-save-intent.json'))
            with self.assertRaises(ValueError): saved_claim(root,'12345678902','Video',video)
            per_source = media/'claims/12345678902/video-save-intent.json'
            per_source.parent.mkdir(parents=True)
            per_source.write_text(json.dumps(dict(claim,SourceId='12345678902',Purpose='Video')), encoding='utf-8')
            self.assertEqual(saved_claim(root,'12345678902','Video',video),str(per_source.resolve()))


if __name__ == '__main__':
    unittest.main()
