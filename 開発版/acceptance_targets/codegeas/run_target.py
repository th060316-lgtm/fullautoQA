"""Execute the standard entrypoint and validate the new result archive."""
import argparse
import json
import subprocess
import sys
import zipfile
from pathlib import Path

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
paths = [p for p in (root / 'RESULTS').glob('*/RESULT_FOR_CHATGPT.zip') if p.parent.name not in previous]
if len(paths) != 1:
    raise SystemExit('EXPECTED_ONE_FRESH_RESULT:' + str(len(paths)))
sys.path.insert(0, str(root / 'CORE'))
from common import validate_result_zip
archive = paths[0]
validate_result_zip(archive, expected_run_id=archive.parent.name)
with zipfile.ZipFile(archive) as z:
    data = json.loads(z.read('result.json').decode('utf-8-sig'))
required_nonpass = [{'case':r['test_case'],'status':r['status'],'reason':r.get('reason_code')}
                   for r in data['results'] if r.get('gate') == 'REQUIRED' and r['status'] != 'PASS']
summary = {'start_qa_exit_code': result.returncode, 'run_id': data['run_id'],
           'overall': data['overall'], 'run_mode': data.get('run_mode'),
           'required_nonpass': required_nonpass,
           'result_archive_integrity': 'PASS', 'result_zip': str(archive),
           'headquarters': data.get('headquarters'),
           'human_test': 'NOT_RUN', 'local_windows_offline': 'NOT_RUN',
           'product_acceptance': 'HOLD', 'stable': 'HOLD'}
(out / 'REAL_GAME_ACCEPTANCE.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2),encoding='utf-8')
print(json.dumps(summary, ensure_ascii=False, indent=2))
raise SystemExit(result.returncode or (1 if required_nonpass else 0))
