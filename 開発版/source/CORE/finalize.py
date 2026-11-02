"""Best-effort independent finalization. Never publish an unvalidated or stale ZIP."""
from pathlib import Path
import os,shutil,traceback,uuid
from common import Evidence,overall,report,write_json,result_zip,validate_result_zip,stamp

def finalize_run(e,data,cleanup=(),latest_path=None,lock=None,execution=None):
    root=e.root;rows=data.setdefault('results',[]);issues=[];published=None;failure=None
    data['qa_status_before_finalization']=data.get('overall',overall(rows))
    def problem(stage,ex):
        detail={'stage':stage,'error':repr(ex),'traceback':traceback.format_exc()};issues.append(detail)
        name='finalization_'+str(len(issues))+'.json'
        try:
            write_json(root/name,detail)
            rows.append(e.result('finalization.'+stage,'HARNESS_ERROR','HARNESS_FINALIZATION_FAILED',[name],gate='REQUIRED'))
        except Exception:
            rows.append({'test_case':'finalization.'+stage,'status':'HARNESS_ERROR','reason_code':'HARNESS_FINALIZATION_FAILED','evidence':[],'gate':'REQUIRED','detail':repr(ex)})
    def refresh():
        if execution is not None:
            try:execution(e,data)
            except Exception as ex:
                problem('coordination',ex)
                data['completion_certified']=False
                data['target_qa_certified']=False
        data['overall']=overall(rows)
        if data['overall']!='PASS':
            data['completion_certified']=False
            for key in tuple(data):
                if key.endswith('_certified') and isinstance(data[key],bool):data[key]=False
        for summary in data.get('prototype_results',{}).values():
            if summary.get('profiles') and any(r.get('gate')=='REQUIRED' and r['status']=='HARNESS_ERROR' and r['test_case'].startswith('finalization.') for r in rows):summary['status']='HARNESS_ERROR'
        data['end_time']=stamp()
    try:
        # A key release/child cleanup failure must not prevent the next cleanup or report.
        for i,callback in enumerate(cleanup):
            try:callback()
            except Exception as ex:problem('cleanup_'+str(i),ex)
        for row in rows:
            if row['status']=='PASS' and (not row.get('evidence') or any(not (root/p).is_file() for p in row['evidence'])):
                row.update(status='HARNESS_ERROR',reason_code='FINAL_EVIDENCE_AUDIT_FAILED');data['completion_certified']=False
        refresh()
        try:report(root,data)
        except Exception as ex:
            problem('report',ex);refresh()
            # Independent minimal report path when rendering fails.
            for name,content in [('result.json',data),('SUMMARY.txt','QA COMPLETE\nOverall Result: '+data['overall']+'\nReport renderer failed; see result.json.\n'),('report.html','<!doctype html><meta charset="utf-8"><p>HARNESS_ERROR: report renderer failed. See result.json.</p>')]:
                try:
                    if isinstance(content,dict):write_json(root/name,content)
                    else:(root/name).write_text(content,encoding='utf-8')
                except Exception as ex:problem('minimal_report',ex)
        try:e.manifest()
        except Exception as ex:
            problem('manifest',ex);refresh()
            # Fresh Evidence has the same scanner; a persistent scanner failure goes to diagnostic packaging below.
            try:report(root,data);Evidence(root,e.run_id).manifest()
            except Exception as ex:problem('minimal_manifest',ex)
        try:published=result_zip(root,require_manifest=True)
        except Exception as ex:
            problem('archive',ex);refresh();failure=repr(ex)
            try:report(root,data)
            except Exception:
                try:write_json(root/'result.json',data)
                except OSError:pass
                for name,body in [('SUMMARY.txt','QA COMPLETE\nOverall Result: HARNESS_ERROR\nRESULT ZIP NOT CREATED: see residual evidence folder.'),('report.html','<!doctype html><meta charset="utf-8"><h1>HARNESS_ERROR</h1><p>Result ZIP creation failed. See result.json.</p>')]:
                    try:(root/name).write_text(body,encoding='utf-8')
                    except OSError:pass
            # Never weaken validation to publish a broken full archive. Preserve originals and
            # return a clearly labelled, self-contained diagnostic ZIP if full packaging fails.
            recovery=root.parent/(root.name+'_recovery')
            try:
                diagnostic=Evidence(recovery,e.run_id)
                write_json(recovery/'packaging_error.json',{'issues':issues,'original_run_directory':str(root),'full_evidence_packaged':False,'original_overall':data['qa_status_before_finalization']})
                diagnostic_rows=[diagnostic.result('result.packaging','HARNESS_ERROR','RESULT_ARCHIVE_FAILED',['packaging_error.json'],gate='REQUIRED')]
                recovered={'run_id':e.run_id,'core_version':data.get('core_version'),'overall':'HARNESS_ERROR','completion_certified':False,'target_qa_certified':False,'results':diagnostic_rows,'original_run_directory':str(root),'diagnostic_archive':True,'full_evidence_packaged':False}
                if execution is not None:execution(diagnostic,recovered)
                report(recovery,recovered);diagnostic.manifest();source=result_zip(recovery,require_manifest=True)
                temporary=root/'result_recovery.tmp';shutil.copyfile(source,temporary);os.replace(temporary,root/'RESULT_FOR_CHATGPT.zip');published=root/'RESULT_FOR_CHATGPT.zip'
                data['overall']='HARNESS_ERROR';data['completion_certified']=False
                data['full_evidence_packaged']=False
                # Keep the original machine data separately; local display must agree with the diagnostic ZIP.
                write_json(root/'pre_packaging_result.json',data)
                for name in ('result.json','report.html','SUMMARY.txt'):
                    shutil.copyfile(recovery/name,root/name)
            except Exception as ex:
                failure=repr(ex);published=None
                # No stale archive may be advertised for this attempted publication.
                try:(root/'RESULT_FOR_CHATGPT.zip').unlink(missing_ok=True)
                except OSError:pass
        if published and latest_path:
            try:write_json(latest_path,{'run_id':e.run_id,'result_zip':str(published),'overall':data['overall'],'diagnostic_archive':bool(failure)})
            except Exception as ex:
                # Display/pointer metadata is outside the sealed Run; keep the real QA result.
                try:write_json(root.parent/(root.name+'_publication_notice.json'),{'result_zip':str(published),'error':repr(ex)})
                except OSError:pass
        return {'zip_created':published is not None,'result_zip':str(published) if published else None,'overall':data['overall'],'error':failure,'residual_path':str(root),'diagnostic_archive':bool(failure and published)}
    finally:
        if lock is not None:
            try:Path(lock).unlink(missing_ok=True)
            except OSError as ex:
                try:write_json(root.parent/(root.name+'_lock_cleanup_notice.json'),{'error':repr(ex),'lock':str(lock)})
                except OSError:pass
