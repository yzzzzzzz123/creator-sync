import json
import sys
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT))
from sync import Ledger

state=json.loads((ROOT/'data/bilibili-test.json').read_text(encoding='utf-8-sig'))
if (ROOT/'data/STOP').exists() or state['max_posts']!=1:
    raise ValueError('Submission stopped or scope changed')
ledger=Ledger(ROOT/'data/sync.sqlite3')
try:
    row=ledger.get(state['note_id'],'bilibili',state['account_id'])
    if row['title']!=state['title'] or row['video_sha256']!=state['video_sha256']:
        raise ValueError('Delivery package changed')
    ledger.claim_submit(state['note_id'],'bilibili',state['account_id'])
    print(json.dumps({'claimed':True,'note_id':state['note_id']}))
finally:
    ledger.close()
