"""Execute START_QA and validate the newly published authoritative Run archive."""
import argparse
import json
import subprocess
import sys
import zipfile
from pathlib import Path


def authoritative_result(root, previous):
    results = Path(root) / 'RESULTS'
    index = json.loads((results / 'latest.json').read_text(encoding='utf-8-sig'))
    run = index.get('run_id')
    if not isinstance(run,str) or not run or run in ('.','..') or any(c in run for c in '/\\:'):
        raise ValueError('INVALID_PUBLISHED_RUN_ID')
    if run in previous:
        raise ValueError('STALE_PUBLISHED_RUN_ID')
    primary = results / run / 'RESULT_FOR_CHATGPT.zip'
    indexed = Path(index['result_zip'])
    if not primary.is_file() or not indexed.samefile(primary):
        raise ValueError('PUBLISHED_ARCHIVE_BINDING_MISMATCH')
    # Recovery companions are retained as evidence; their directory is not a new Run.
    return primary


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--candidate-root', required=True)
    ap.add_argument('--evidence', required=True)
    ns = ap.parse_args()
    root = Path(ns.candidate_root).resolve()
    out = Path(ns.evidence).resolve()
    out.mkdir(parents=True, exist_ok=True)
    previous = {p.name for p in (root / 'RESULTS').glob('*') if p.is_dir()}
    with (out / 'START_QA.log').open('wb') as log:
        result = subprocess.run(['cmd.exe', '/d', '/c', 'START_QA.cmd'], cwd=root,
                                stdout=log, stderr=subprocess.STDOUT, timeout=1200)
    archive = authoritative_result(root,previous)
    sys.path.insert(0, str(root / 'CORE'))
    from common import validate_result_zip
    validate_result_zip(archive, expected_run_id=archive.parent.name)
    with zipfile.ZipFile(archive) as z:
        data = json.loads(z.read('result.json').decode('utf-8-sig'))
    nonpass = [{'case':r['test_case'],'status':r['status'],'reason':r.get('reason_code')}
               for r in data['results'] if r.get('gate') == 'REQUIRED' and r['status'] != 'PASS']
    summary = {'start_qa_exit_code': result.returncode, 'run_id': data['run_id'],
               'overall': data['overall'], 'run_mode': data.get('run_mode'),
               'required_nonpass': nonpass, 'result_archive_integrity': 'PASS',
               'diagnostic_archive': bool(data.get('diagnostic_archive')),
               'full_evidence_packaged': data.get('full_evidence_packaged',not data.get('diagnostic_archive',False)),
               'result_zip': str(archive),'headquarters': data.get('headquarters'),
               'human_test': 'NOT_RUN','local_windows_offline': 'NOT_RUN',
               'product_acceptance': 'HOLD','stable': 'HOLD'}
    (out / 'REAL_GAME_ACCEPTANCE.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2),encoding='utf-8')
    print(json.dumps(summary,ensure_ascii=False,indent=2))
    return result.returncode or (1 if nonpass else 0)

if __name__ == '__main__':
    raise SystemExit(main())

