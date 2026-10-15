"""Claim a single prepared native-RPA submission. No network or browser operations."""
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from sync import Ledger


def main():
    package = json.loads(Path(sys.argv[1]).read_text(encoding='utf-8-sig'))
    if (ROOT/'data/STOP').exists():
        raise ValueError('User STOP file exists')
    ledger = Ledger(ROOT/'data/sync.sqlite3')
    try:
        row = ledger.prepare(package['SourceKey'], package['Platform'], package['AccountId'], package['Caption'])
        if row['note_id'] != package['SourceKey'] or row['status'] != 'ready' or row.get('intent_at'):
            raise ValueError('An existing delivery must be reconciled; no new submit')
        ledger.claim_submit(row['note_id'], package['Platform'], package['AccountId'])
    finally:
        ledger.close()
    print('Single submission claimed; result must be reconciled, never replayed.')


if __name__ == '__main__':
    main()
