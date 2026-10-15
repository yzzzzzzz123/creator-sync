import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path

from sync import Ledger, sha256

PROJECT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('creator_sync_entry', PROJECT/'skill/scripts/main.py')
entry = importlib.util.module_from_spec(spec)
spec.loader.exec_module(entry)


class EntryTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        (self.root/'skill').mkdir()
        (self.root/'skill/sites.json').write_bytes((PROJECT/'skill/sites.json').read_bytes())
        entry.write_json(self.root/'config.local.json', {'source':{'account_id':'owner'},
                         'targets':{'bilibili':{'account_id':'bili-owner'},'youtube':{'account_id':'yt-owner'}}})
        self.video = self.root/'video.mp4';self.video.write_bytes(b'fixture media')
        self.db = Ledger(self.root/'data/sync.sqlite3')
        self.db.observe({'note_id':'n','title':'曲名','url':'https://www.xiaohongshu.com/explore/n',
                         'video_path':str(self.video),'video_sha256':sha256(self.video)})
        self.window = {'WindowHandle':123,'ProcessId':7,'ProcessStartUtc':'start','TabNames':['小红书'],
                       'IsIncognito':False,'Foreground':False}

    def tearDown(self):
        self.db.close();self.tmp.cleanup()

    def published(self, platform, account):
        self.db.prepare('n',platform,account,'Title')
        self.db.record('n',platform,account,'published','v','https://example.test/v',{'backend':True})

    def test_existing_posts_are_skipped_without_changing_delivery(self):
        self.published('youtube','yt-owner');self.published('bilibili','bili-owner')
        before = self.db.status()
        result = entry.Flow(self.root).begin(entry.TARGETS,'n')
        self.assertEqual(result['next_step'],'complete')
        self.assertEqual(self.db.status(),before)

    def test_unknown_submission_survives_resume(self):
        self.db.prepare('n','bilibili','bili-owner','Title')
        self.db.claim_submit('n','bilibili','bili-owner')
        flow=entry.Flow(self.root);flow.begin(entry.TARGETS,'n')
        before=self.db.get('n','bilibili','bili-owner')
        result=flow.resume()
        self.assertEqual(result['next_step'],'reconcile')
        self.assertEqual(self.db.get('n','bilibili','bili-owner'),before)

    def test_latest_means_live_discovery_not_first_pinned_card(self):
        result=entry.selection(self.root,entry.TARGETS)
        self.assertEqual(result['next_step'],'discover')
        self.assertIsNone(result['source'])
        self.assertEqual(result['cover_layout']['text_anchor'],'center')

    def test_active_batch_cannot_be_replaced_or_expand_to_second_note(self):
        flow=entry.Flow(self.root);first=flow.begin(entry.TARGETS)
        with self.assertRaises(ValueError):flow.begin(entry.TARGETS)
        selected=flow.select('n')
        self.assertEqual(selected['run_id'],first['run_id'])
        with self.assertRaises(ValueError):flow.select('another')

    def test_stop_requires_explicit_resume(self):
        flow=entry.Flow(self.root);flow.begin(entry.TARGETS)
        (self.root/'data/STOP').touch()
        with self.assertRaises(ValueError):flow.resume()
        flow.resume(clear_stop=True)
        self.assertFalse((self.root/'data/STOP').exists())

    def test_no_chrome_launches_exact_three_resolved_addresses(self):
        snapshots=iter([{'Desktop':'Default','InputDesktop':'Default','Windows':[]},
                        {'Desktop':'Default','InputDesktop':'Default','Windows':[self.window]}])
        launches=[];attaches=[]
        result=entry.ensure_browser(self.root,open_missing=True,discover=lambda:next(snapshots),
                  launch=lambda urls:launches.append(urls),attach=lambda handle,sites:attaches.append((handle,sites)) or {})
        self.assertEqual(len(launches),1)
        self.assertEqual(launches[0],['https://www.xiaohongshu.com/user/profile/owner',
                         'https://member.bilibili.com/platform/home','https://studio.youtube.com/channel/yt-owner/videos'])
        self.assertEqual(attaches,[(123,None)])
        self.assertTrue(result['LaunchedChrome'])

    def test_existing_browser_is_taken_over_without_launch(self):
        def unexpected_launch(urls):self.fail('Existing Chrome must not be relaunched')
        result=entry.ensure_browser(self.root,discover=lambda:{'Desktop':'Default','InputDesktop':'Default','Windows':[self.window]},
                  launch=unexpected_launch,attach=lambda handle,sites:{'window':handle})
        self.assertFalse(result['LaunchedChrome']);self.assertEqual(result['window'],123)

    def test_only_private_window_opens_normal_session_and_leaves_private_alone(self):
        private=dict(self.window,IsIncognito=True,WindowHandle=999)
        snapshots=iter([{'Desktop':'Default','InputDesktop':'Default','Windows':[private]},
                        {'Desktop':'Default','InputDesktop':'Default','Windows':[private,self.window]}])
        launches=[];handles=[]
        entry.ensure_browser(self.root,discover=lambda:next(snapshots),launch=lambda urls:launches.append(urls),
                             attach=lambda handle,sites:handles.append(handle) or {})
        self.assertEqual(len(launches),1);self.assertEqual(handles,[123])

    def test_private_window_or_locked_desktop_is_not_taken_over(self):
        with self.assertRaises(ValueError):entry.choose_window([dict(self.window,IsIncognito=True)])
        with self.assertRaises(ValueError):entry.ensure_browser(self.root,discover=lambda:{'Desktop':'Default','InputDesktop':'Winlogon','Windows':[self.window]})

    def test_process_restart_invalidates_saved_binding(self):
        second=dict(self.window,WindowHandle=456,Foreground=True,ProcessStartUtc='new')
        selected=entry.choose_window([self.window,second],dict(self.window,ProcessStartUtc='obsolete'))
        self.assertEqual(selected['WindowHandle'],456)

    def test_readonly_status_does_not_create_database(self):
        other=self.root/'empty';other.mkdir()
        self.assertEqual(entry.database(other),([],[]))
        self.assertFalse((other/'data').exists())

    def test_another_startup_cannot_acquire_control(self):
        with entry.control_lock(self.root):
            with self.assertRaises(ValueError):
                with entry.control_lock(self.root):pass

    def test_stop_remains_available_while_startup_holds_control_lock(self):
        from contextlib import redirect_stdout
        from io import StringIO
        with entry.control_lock(self.root), redirect_stdout(StringIO()):
            self.assertEqual(entry.main(['--root',str(self.root),'--json','stop']),0)
        self.assertTrue((self.root/'data/STOP').exists())


if __name__=='__main__':unittest.main()
