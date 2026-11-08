import hashlib,json,tempfile,unittest
from pathlib import Path
from split_candidate import split

class CandidateExportTests(unittest.TestCase):
    def test_rejoined_bytes_and_each_part_match_frozen_archive(self):
        with tempfile.TemporaryDirectory() as td:
            root=Path(td);archive=root/'candidate.zip';data=b'complete candidate bytes';archive.write_bytes(data)
            identity={'candidate_file':archive.name,'candidate_size':len(data),'candidate_sha256':hashlib.sha256(data).hexdigest()}
            proof=split(archive,identity,root/'parts',5)
            self.assertEqual(b''.join((root/'parts'/r['file']).read_bytes() for r in proof['parts']),data)
            for row in proof['parts']:
                part=(root/'parts'/row['file']).read_bytes()
                self.assertEqual(len(part),row['size']);self.assertEqual(hashlib.sha256(part).hexdigest(),row['sha256'])
    def test_changed_candidate_cannot_be_exported(self):
        with tempfile.TemporaryDirectory() as td:
            root=Path(td);archive=root/'candidate.zip';archive.write_bytes(b'changed')
            with self.assertRaisesRegex(ValueError,'IDENTITY_MISMATCH'):
                split(archive,{'candidate_file':archive.name,'candidate_size':7,'candidate_sha256':'old'},root/'parts')

if __name__=='__main__':unittest.main()
