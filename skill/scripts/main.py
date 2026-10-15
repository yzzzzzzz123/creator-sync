"""Creator Sync 的统一入口：地址簿、Chrome 接管、任务计划与断点恢复。

启动后由调用本 Skill 的 Codex 执行网页 RPA；本入口不启动第二个 Agent 或后台发文服务。
"""
import argparse
import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import time
import uuid
from datetime import datetime, timezone
from contextlib import contextmanager, nullcontext
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TARGETS = ('bilibili', 'youtube')
FINAL = {'published', 'existing'}
UNKNOWN = {'submitting', 'submitted', 'processing'}
COVER_LAYOUT = {'text_align': 'center', 'text_anchor': 'center', 'crop_ratios': ['4:3', '16:9']}


@contextmanager
def control_lock(root):
    path = root / 'data/skill/control.lock'
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open('a+b') as stream:
        stream.seek(0, 2)
        if not stream.tell():
            stream.write(b'0');stream.flush()
        stream.seek(0)
        if os.name == 'nt':
            import msvcrt
            try:
                msvcrt.locking(stream.fileno(), msvcrt.LK_NBLCK, 1)
            except OSError as error:
                raise ValueError('另一个启动操作正在执行，请勿同时启动。') from error
            try:
                yield
            finally:
                stream.seek(0);msvcrt.locking(stream.fileno(), msvcrt.LK_UNLCK, 1)
        else:
            import fcntl
            try:
                fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError as error:
                raise ValueError('另一个启动操作正在执行，请勿同时启动。') from error
            try:
                yield
            finally:
                fcntl.flock(stream, fcntl.LOCK_UN)


def read_json(path, default=None):
    return json.loads(path.read_text(encoding='utf-8-sig')) if path.exists() else default


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + '.' + uuid.uuid4().hex + '.tmp')
    try:
        with temporary.open('w', encoding='utf-8') as stream:
            json.dump(value, stream, ensure_ascii=False, indent=2)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def addresses(root):
    config = read_json(root / 'config.local.json', {})
    book = read_json(root / 'skill/sites.json')
    resolved = []
    for key, settings in book.items():
        account = (config.get('source', {}) if key == 'xiaohongshu' else config.get('targets', {}).get(key, {}))
        account_id = account.get('account_id', '')
        if account_id.startswith('SET_'):
            account_id = ''
        item = dict(settings, key=key)
        if account_id:
            item['profile_url'] = item.pop('profile_template').format(account_id=account_id)
            if key == 'xiaohongshu':
                item['start_url'] = item['profile_url']
            elif key == 'youtube':
                item['start_url'] = item.pop('studio_template').format(account_id=account_id)
        item.pop('profile_template', None)
        item.pop('studio_template', None)
        resolved.append(item)
    return resolved


def database(root):
    path = root / 'data/sync.sqlite3'
    if not path.exists():
        return [], []
    connection = sqlite3.connect(path.resolve().as_uri() + '?mode=ro', uri=True)
    connection.row_factory = sqlite3.Row
    try:
        return ([dict(r) for r in connection.execute('SELECT * FROM sources')],
                [dict(r) for r in connection.execute('SELECT * FROM deliveries')])
    finally:
        connection.close()


def selection(root, platforms, note_id=None):
    config = read_json(root / 'config.local.json', {})
    sources, deliveries = database(root)
    missing_accounts = [p for p in platforms if not config.get('targets', {}).get(p, {}).get('account_id') or config['targets'][p]['account_id'].startswith('SET_')]
    result = {'targets': [], 'needs_account_binding': missing_accounts}
    if note_id:
        source = next((s for s in sources if s['note_id'] == note_id), None)
        if not source:
            raise ValueError('本地尚无这条源笔记；先通过小红书本人主页采集。')
        result['source'] = source
        for platform in platforms:
            account = config.get('targets', {}).get(platform, {}).get('account_id', '')
            matches = [d for d in deliveries if d['platform'] == platform and d['account_id'] == account and
                       (d['note_id'] == note_id or (source.get('video_sha256') and d['video_sha256'] == source['video_sha256']))]
            row = matches[0] if matches else None
            action = 'prepare'
            if row and row['status'] in FINAL:
                action = 'skip_published'
            elif row and (row['status'] in UNKNOWN or row.get('intent_at')):
                action = 'reconcile_existing_submission'
            elif row and row['status'] != 'ready':
                action = 'review_delivery'
            result['targets'].append({'platform': platform, 'account_id': account, 'action': action,
                                      'status': row['status'] if row else 'not_prepared',
                                      'target_url': row['target_url'] if row else None})
    else:
        result['source'] = None
        # Loaded profile order can contain pinned old notes. Never call the first saved card "latest".
        result['discovery_required'] = True
    actions = {d['action'] for d in result['targets']}
    if missing_accounts:
        stage = 'bind_accounts'
    elif 'reconcile_existing_submission' in actions or 'review_delivery' in actions:
        stage = 'reconcile'
    elif result.get('discovery_required'):
        stage = 'discover'
    elif actions == {'skip_published'}:
        stage = 'complete'
    else:
        stage = 'prepare'
    result['next_step'] = stage
    result['cover_layout'] = dict(COVER_LAYOUT)
    return result


def choose_window(windows, binding=None, requested=None):
    normal = [w for w in windows if not w['IsIncognito']]
    if requested:
        candidates = [w for w in normal if w['WindowHandle'] == requested]
    elif binding and any(w['WindowHandle'] == binding.get('WindowHandle') and w['ProcessId'] == binding.get('ProcessId') and w['ProcessStartUtc'] == binding.get('ProcessStartUtc') for w in normal):
        candidates = [w for w in normal if w['WindowHandle'] == binding['WindowHandle']]
    else:
        foreground = [w for w in normal if w.get('Foreground')]
        candidates = foreground or normal
    if len(candidates) > 1:
        candidates = [w for w in candidates if any(any(word in title for word in ('小红书', '创作中心', 'YouTube')) for title in w.get('TabNames', []))] or candidates
    if len(candidates) != 1:
        raise ValueError('有多个 Chrome 窗口，请用 --window-handle 指定现场窗口；不会替换浏览器资料目录。')
    return candidates[0]


def session_call(root, *arguments):
    if os.name != 'nt':
        raise ValueError('Chrome 接管需要 Windows 原生桌面。')
    result = subprocess.run(['powershell.exe', '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
                             '-File', str(root / 'skill/scripts/Session.ps1'), *map(str, arguments)],
                            capture_output=True, encoding='utf-8-sig', errors='replace',
                            creationflags=subprocess.CREATE_NO_WINDOW, timeout=45, cwd=root)
    if result.returncode:
        raise ValueError(result.stderr.strip() or '原生 Chrome 会话操作失败。')
    return json.loads(result.stdout.strip())


def chrome_executable():
    import winreg
    for hive in (winreg.HKEY_CURRENT_USER, winreg.HKEY_LOCAL_MACHINE):
        try:
            with winreg.OpenKey(hive, r'SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe') as key:
                path = Path(winreg.QueryValue(key, None))
                if path.is_file():
                    return path
        except OSError:
            pass
    for variable in ('PROGRAMFILES', 'PROGRAMFILES(X86)', 'LOCALAPPDATA'):
        path = Path(os.environ.get(variable, '')) / 'Google/Chrome/Application/chrome.exe'
        if path.is_file():
            return path
    raise ValueError('未找到 Chrome，请先安装 Chrome；不会改用其他浏览器或创建空白账号资料。')


def ensure_browser(root, requested=None, open_missing=False, discover=None, launch=None, attach=None):
    if (root / 'data/STOP').exists():
        raise ValueError('STOP 已存在；请确认继续后使用 resume --clear-stop。')
    discover = discover or (lambda: session_call(root, '-Action', 'Discover'))
    snapshot = discover()
    if snapshot['Desktop'] != 'Default' or snapshot['InputDesktop'] != 'Default':
        raise ValueError('请先解锁 Windows 默认桌面。')
    sites = addresses(root)
    windows = [w for w in snapshot['Windows'] if not w['IsIncognito']]
    launched = False
    if not windows:
        if requested:
            raise ValueError('指定窗口已经关闭，请重新选择窗口。')
        if (root / 'data/STOP').exists():
            raise ValueError('Chrome 启动前收到停止请求。')
        if launch:
            launch([s['start_url'] for s in sites])
        else:
            subprocess.Popen([str(chrome_executable()), *[s['start_url'] for s in sites]],
                             creationflags=subprocess.CREATE_NO_WINDOW, cwd=root)
        launched = True
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            snapshot = discover()
            windows = [w for w in snapshot['Windows'] if not w['IsIncognito']]
            if windows:
                break
            time.sleep(.4)
        if not windows:
            raise ValueError('Chrome 启动后未在限时内出现；保留现场，不重复启动。')
    window = choose_window(windows, read_json(root / 'data/browser-binding.json'), requested)
    attach = attach or (lambda handle, site_file: session_call(root, '-Action', 'Attach', '-WindowHandle', handle,
                        *(['-SitesFile', site_file] if site_file else [])))
    site_file = None
    try:
        # A freshly launched Chrome already received all three URLs; do not race it with extra tabs.
        if open_missing and not launched:
            directory = root / 'data/skill';directory.mkdir(parents=True, exist_ok=True)
            descriptor, name = tempfile.mkstemp(prefix='sites-', suffix='.json', dir=directory)
            with os.fdopen(descriptor, 'w', encoding='utf-8') as stream:
                json.dump(sites, stream, ensure_ascii=False)
            site_file = Path(name)
        result = attach(window['WindowHandle'], str(site_file) if site_file else None)
    finally:
        if site_file:
            site_file.unlink(missing_ok=True)
    result.update(LaunchedChrome=launched, Sites=sites)
    return result


class Flow:
    def __init__(self, root):
        self.root = root
        self.path = root / 'data/skill/active-run.json'

    def begin(self, platforms, note_id=None, browser=None):
        if (self.root / 'data/STOP').exists():
            raise ValueError('任务已停止；使用 resume --clear-stop 明确恢复。')
        previous = read_json(self.path)
        if previous and previous['next_step'] != 'complete':
            raise ValueError('已有未结束任务；请使用 resume，不创建另一轮任务。')
        result = selection(self.root, platforms, note_id)
        result.update(run_id=uuid.uuid4().hex, note_id=note_id,
                      platforms=list(platforms), max_source_notes=1,
                      started_at=datetime.now(timezone.utc).isoformat(),
                      executor='codex-native-rpa', browser=browser,
                      skill='skill/SKILL.md')
        # Keep completed batches for review instead of discarding them when starting a new one.
        if previous:
            write_json(self.path.parent / 'history' / (previous['run_id'] + '.json'), previous)
        write_json(self.path, result)
        return result

    def resume(self, clear_stop=False):
        state = read_json(self.path)
        if not state:
            raise ValueError('没有可恢复任务，请先 start。')
        stop = self.root / 'data/STOP'
        if stop.exists() and not clear_stop:
            raise ValueError('STOP 已存在；需要 resume --clear-stop 明确恢复。')
        if clear_stop:
            stop.unlink(missing_ok=True)
        refreshed = selection(self.root, state['platforms'], state['note_id'])
        state.update(refreshed)
        write_json(self.path, state)
        return state

    def select(self, note_id):
        if (self.root / 'data/STOP').exists():
            raise ValueError('任务已停止。')
        state = read_json(self.path)
        if not state:
            raise ValueError('先 start，再选择现场采集的源笔记。')
        if state['note_id'] and state['note_id'] != note_id:
            raise ValueError('本轮限定 1 条源笔记，不能替换为另一条。')
        state.update(selection(self.root, state['platforms'], note_id))
        state['note_id'] = note_id
        write_json(self.path, state)
        return state


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=ROOT, help=argparse.SUPPRESS)
    parser.add_argument('--json', action='store_true', help='输出完整 JSON')
    parser.add_argument('action', nargs='?', default='status', choices=['status', 'sites', 'plan', 'start', 'attach', 'resume', 'select', 'stop'])
    parser.add_argument('--targets', nargs='+', choices=TARGETS, default=list(TARGETS))
    parser.add_argument('--note-id', help='明确指定源笔记；默认先现场发现最新视频')
    parser.add_argument('--window-handle', type=int)
    parser.add_argument('--dry-run', action='store_true', help='只生成计划，不操作浏览器或写任务')
    parser.add_argument('--clear-stop', action='store_true')
    args = parser.parse_args(argv)
    if args.action == 'select' and not args.note_id:
        parser.error('select 需要 --note-id')
    root = args.root.resolve()
    flow = Flow(root)
    try:
        with (control_lock(root) if args.action in ('start','attach','resume','select') and not args.dry_run else nullcontext()):
            if args.action == 'sites':
                result = {'sites': addresses(root)}
            elif args.action == 'status':
                sources, deliveries = database(root)
                result = {'source_count': len(sources), 'deliveries': [{k: d[k] for k in ('note_id','platform','status','target_url')} for d in deliveries],
                          'active_run': read_json(flow.path), 'stopped': (root/'data/STOP').exists(), 'scheduler_enabled': False,
                          'cover_layout': COVER_LAYOUT}
            elif args.action == 'plan' or args.dry_run:
                result = selection(root, args.targets, args.note_id)
                result['dry_run'] = True
            elif args.action == 'stop':
                (root/'data').mkdir(parents=True, exist_ok=True)
                (root/'data/STOP').touch()
                result = {'stopped': True, 'message': '后续 RPA 输入与提交停止；不关闭本人浏览器。'}
            elif args.action == 'attach':
                result = ensure_browser(root, args.window_handle)
            elif args.action == 'select':
                result = flow.select(args.note_id)
            elif args.action == 'start':
                # Check unfinished batches before any browser action.
                previous = read_json(flow.path)
                if previous and previous['next_step'] != 'complete':
                    raise ValueError('已有未结束任务；请使用 resume。')
                planned = selection(root, args.targets, args.note_id)
                browser = None if planned['next_step'] == 'complete' else ensure_browser(root, args.window_handle, open_missing=True)
                result = flow.begin(args.targets, args.note_id, browser)
            else:
                result = flow.resume(args.clear_stop)
                if result['next_step'] != 'complete':
                    result['browser'] = ensure_browser(root, args.window_handle, open_missing=True)
                    write_json(flow.path, result)
        if args.json:
            print(json.dumps(result, ensure_ascii=False, indent=2))
        else:
            print('Creator Sync · 小红书 → B站 / YouTube')
            if args.action == 'sites':
                for site in result['sites']:
                    print(f"{site['key']}: {site['start_url']}")
            elif args.action == 'status':
                print(f"素材基线：{result['source_count']} 条；已登记发布：{len(result['deliveries'])} 条")
                for row in result['deliveries']:
                    print(f"{row['platform']} · {row['status']} · {row['target_url'] or '待核验'}")
                print('自动调度：关闭；后续封面文字：居中')
            elif args.action == 'attach':
                print('已启动 Chrome 并打开三个站点。' if result['LaunchedChrome'] else '已接管当前正常 Chrome 窗口，保留原登录会话。')
            elif args.action == 'stop':
                print(result['message'])
            else:
                labels = {'discover':'现场读取本人小红书，确认最新视频（排除置顶旧视频）', 'prepare':'准备素材、居中封面和分平台发布包',
                          'reconcile':'核对既有提交结果，禁止重复投稿', 'bind_accounts':'核对并补齐目标账号绑定', 'complete':'所选内容已完成，跳过重复发布'}
                print('下一步：' + labels[result['next_step']])
                print('网页操作由调用 skill/SKILL.md 的 Codex 继续执行；启动程序不独立后台发文。')
            print('Skill 入口：' + str(root/'skill/SKILL.md'))
        return 0
    except (ValueError, OSError, sqlite3.Error, subprocess.SubprocessError) as error:
        if args.json:
            print(json.dumps({'ok':False,'error':str(error)}, ensure_ascii=False))
        else:
            print('停止：' + str(error), file=sys.stderr)
        return 1


if __name__ == '__main__':
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(encoding='utf-8')
        sys.stderr.reconfigure(encoding='utf-8')
    raise SystemExit(main())
