"""Export verified Candidate bytes without rebuilding the archive."""
import argparse,hashlib,json
from pathlib import Path

def digest(path):
    with Path(path).open('rb') as stream:return hashlib.file_digest(stream,'sha256').hexdigest()

def split(archive,identity,output,chunk_size=384*1024*1024):
    archive=Path(archive);output=Path(output)
    if chunk_size<=0:raise ValueError('INVALID_CHUNK_SIZE')
    if archive.name!=identity['candidate_file'] or archive.stat().st_size!=identity['candidate_size'] or digest(archive)!=identity['candidate_sha256']:
        raise ValueError('CANDIDATE_IDENTITY_MISMATCH')
    if output.exists():raise ValueError('EXPORT_DESTINATION_EXISTS')
    output.mkdir(parents=True);rows=[]
    with archive.open('rb') as stream:
        while data:=stream.read(chunk_size):
            path=output/('candidate.part'+str(len(rows)+1).zfill(3));path.write_bytes(data)
            rows.append({'file':path.name,'size':len(data),'sha256':hashlib.sha256(data).hexdigest()})
    proof={'candidate_file':archive.name,'candidate_size':archive.stat().st_size,
           'candidate_sha256':identity['candidate_sha256'],'parts':rows}
    (output/'FINAL_CANDIDATE_PARTS.json').write_text(json.dumps(proof,indent=2),encoding='utf-8')
    return proof

def main():
    ap=argparse.ArgumentParser();ap.add_argument('--archive',required=True);ap.add_argument('--identity',required=True);ap.add_argument('--output',required=True)
    args=ap.parse_args();split(args.archive,json.loads(Path(args.identity).read_text(encoding='utf-8-sig')),args.output)

if __name__=='__main__':main()
