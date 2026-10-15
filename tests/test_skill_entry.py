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
LEGACY_TARGETS = ('bilibili', 'youtube')


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
        result = entry.Flow(self.root).begin(LEGACY_TARGETS,'n')
        self.assertEqual(result['next_step'],'complete')
        self.assertEqual(self.db.status(),before)

    def test_unknown_submission_survives_resume(self):
        self.db.prepare('n','bilibili','bili-owner','Title')
        self.db.claim_submit('n','bilibili','bili-owner')
        flow=entry.Flow(self.root);flow.begin(LEGACY_TARGETS,'n')
        before=self.db.get('n','bilibili','bili-owner')
        result=flow.resume()
        self.assertEqual(result['next_step'],'reconcile')
        self.assertEqual(self.db.get('n','bilibili','bili-owner'),before)

    def test_latest_means_live_discovery_not_first_pinned_card(self):
        result=entry.selection(self.root,LEGACY_TARGETS)
        self.assertEqual(result['next_step'],'discover')
        self.assertIsNone(result['source'])
        self.assertEqual(result['cover_layout']['text_anchor'],'center')

    def test_active_batch_cannot_be_replaced_or_expand_to_second_note(self):
        flow=entry.Flow(self.root);first=flow.begin(LEGACY_TARGETS)
        with self.assertRaises(ValueError):flow.begin(LEGACY_TARGETS)
        selected=flow.select('n')
        self.assertEqual(selected['run_id'],first['run_id'])
        with self.assertRaises(ValueError):flow.select('another')

    def test_stop_requires_explicit_resume(self):
        flow=entry.Flow(self.root);flow.begin(LEGACY_TARGETS)
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

    def douyin_config(self):
        config=json.loads((PROJECT/'config.example.json').read_text(encoding='utf-8'))
        config['source']['account_id']='owner'
        config['targets']['bilibili']['account_id']='bili-owner'
        config['targets']['youtube']['account_id']='yt-owner'
        config['targets']['xiaohongshu']['account_id']='xhs-owner'
        entry.write_json(self.root/'config.local.json',config)
        return config

    def test_douyin_source_resolves_six_sites_with_separate_routes(self):
        self.douyin_config()
        sites=entry.addresses(self.root)
        self.assertEqual(len(sites),6)
        self.assertEqual([s['key'] for s in sites if s['role']=='source'],['douyin'])
        self.assertEqual([s['key'] for s in sites if s['network']=='direct'],['douyin','xiaohongshu','bilibili'])
        self.assertEqual([s['key'] for s in sites if s['network']=='proxy'],['youtube','tiktok','instagram'])
        self.assertNotIn('profile_url',next(s for s in sites if s['key']=='instagram'))

    def test_no_chrome_douyin_flow_opens_all_six_once(self):
        self.douyin_config()
        snapshots=iter([{'Desktop':'Default','InputDesktop':'Default','Windows':[]},
                        {'Desktop':'Default','InputDesktop':'Default','Windows':[self.window]}])
        launches=[]
        entry.ensure_browser(self.root,open_missing=True,discover=lambda:next(snapshots),
                             launch=lambda urls:launches.append(urls),attach=lambda handle,sites:{})
        self.assertEqual(len(launches),1)
        self.assertEqual(len(launches[0]),6)
        self.assertIn('https://www.douyin.com/user/self',launches[0])
        self.assertIn('https://www.tiktok.com/tiktokstudio/upload',launches[0])
        self.assertIn('https://www.instagram.com/',launches[0])

    def test_missing_new_accounts_does_not_block_preparing_bound_targets(self):
        self.douyin_config()
        self.db.observe({'note_id':'123','source_platform':'douyin','title':'曲名','url':'https://www.douyin.com/video/123',
                         'video_path':str(self.video),'video_sha256':sha256(self.video)})
        result=entry.selection(self.root,entry.TARGETS,'douyin:123')
        self.assertEqual(result['next_step'],'prepare')
        self.assertEqual(result['needs_account_binding'],['tiktok','instagram'])
        self.assertEqual({d['platform']:d['action'] for d in result['targets']},
                         {'xiaohongshu':'prepare','bilibili':'prepare','youtube':'prepare','tiktok':'bind_account','instagram':'bind_account'})

    def test_source_switch_does_not_silently_resume_unselected_old_batch(self):
        flow=entry.Flow(self.root);flow.begin(LEGACY_TARGETS)
        self.douyin_config()
        with self.assertRaises(ValueError):flow.resume()

    def test_old_receipt_and_hash_still_skip_after_source_switch(self):
        self.published('youtube','yt-owner')
        self.douyin_config()
        self.db.observe({'note_id':'123','source_platform':'douyin','title':'另一标题','url':'https://www.douyin.com/video/123',
                         'video_path':str(self.video),'video_sha256':sha256(self.video)})
        result=entry.selection(self.root,['youtube'],'douyin:123')
        self.assertEqual(result['targets'][0]['action'],'skip_published')
        self.assertEqual(result['targets'][0]['delivery_note_id'],'n')
        self.assertEqual(result['next_step'],'complete')


if __name__=='__main__':unittest.main()
