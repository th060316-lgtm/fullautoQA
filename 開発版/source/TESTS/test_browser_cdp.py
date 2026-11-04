"""Unit/protocol checks, never substituted for real browser acceptance."""
import base64,hashlib,json,socket,struct,sys,tempfile,threading,unittest,zlib
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'CORE'))
from browser_backend import _CDP,_png_bmp,CDPBrowserDisplay,select_browser_display
from adapters import Adapter,image_features

def png(width,height,color,data):
    def chunk(kind,raw):return struct.pack('!I',len(raw))+kind+raw+struct.pack('!I',zlib.crc32(kind+raw)&0xffffffff)
    return b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('!IIBBBBB',width,height,8,color,0,0,0))+chunk(b'IDAT',zlib.compress(data))+chunk(b'IEND',b'')

class Contracts(unittest.TestCase):
    def test_no_fallback(self):
        with self.assertRaisesRegex(OSError,'BROWSER_TRANSPORT_UNSUPPORTED'):select_browser_display({'display':{'transport':'unknown'}},'.',None)
    def test_runtime_engine_required(self):
        with tempfile.TemporaryDirectory() as td:
            Path(td,'index.html').write_text('unit')
            with self.assertRaisesRegex(OSError,'BROWSER_RUNTIME_ENGINE_REQUIRED'):CDPBrowserDisplay({'display':{'target':'index.html'}},td,None)
    def config(self,td):
        root=Path(td);(root/'index.html').write_text('unit');exe=root/'runtime';exe.write_text('unit protocol dummy, not browser');user=root/'user';user.mkdir();(user/'DevToolsActivePort').write_text('12345\n/devtools/browser/unit\n')
        return {'display':{'kind':'browser','transport':'cdp','target':'index.html','endpoint':'user/DevToolsActivePort','viewport':{'width':2,'height':1},'runtime':{'engine':'chromium-cdp','executable':str(exe),'sha256':hashlib.sha256(exe.read_bytes()).hexdigest()}}},SimpleNamespace(pid=42,args=[str(exe),'--remote-debugging-port=0','--user-data-dir='+str(user),'about:blank'],poll=lambda:None)
    def test_hash_required(self):
        with tempfile.TemporaryDirectory() as td:
            p,process=self.config(td);p['display']['runtime']['sha256']='bad'
            with self.assertRaisesRegex(OSError,'BROWSER_RUNTIME_HASH_MISMATCH'):CDPBrowserDisplay(p,td,process)
    def test_process_mismatch(self):
        with tempfile.TemporaryDirectory() as td:
            p,process=self.config(td);process.args[0]='different'
            with self.assertRaisesRegex(OSError,'BROWSER_RUNTIME_PROCESS_MISMATCH'):CDPBrowserDisplay(p,td,process)
    def test_endpoint_escape(self):
        with tempfile.TemporaryDirectory() as td:
            p,process=self.config(td);p['display']['endpoint']='../DevToolsActivePort'
            with self.assertRaisesRegex(OSError,'BROWSER_CDP_ENDPOINT_OUTSIDE_WORK'):CDPBrowserDisplay(p,td,process)
    def test_blank_launch_required(self):
        with tempfile.TemporaryDirectory() as td:
            p,process=self.config(td);process.args[-1]='index.html'
            with self.assertRaisesRegex(OSError,'BROWSER_CDP_BLANK_LAUNCH_REQUIRED'):CDPBrowserDisplay(p,td,process)
    def test_isolated_launch_required(self):
        with tempfile.TemporaryDirectory() as td:
            p,process=self.config(td);process.args.remove('--remote-debugging-port=0')
            with self.assertRaisesRegex(OSError,'BROWSER_CDP_ISOLATED_LAUNCH_REQUIRED'):CDPBrowserDisplay(p,td,process)
    def test_adapter_capabilities(self):
        adapter=Adapter({'display':{'kind':'browser'}},{'desktop':SimpleNamespace(capabilities=lambda:{'console':True,'native_window':False})})
        self.assertTrue(adapter.capabilities()['browser']['console']);self.assertFalse(adapter.capabilities()['internal_state'])
    def test_remote_websocket_refused_before_connect(self):
        with patch('browser_backend.socket.create_connection') as connect:
            with self.assertRaisesRegex(OSError,'BROWSER_CDP_ENDPOINT_FORBIDDEN'):_CDP('ws://example.com:80/x',lambda e:None)
            connect.assert_not_called()
    def display(self):
        d=object.__new__(CDPBrowserDisplay);d.width,d.height=640,480;d.held=set();d.lock=threading.RLock();sent=[];d.call=lambda method,params:sent.append((method,params));return d,sent
    def test_invalid_coordinates(self):
        d,sent=self.display()
        for value in [float('nan'),float('inf'),-1,2,True,None]:
            with self.assertRaises(ValueError):d.point({'x':value,'y':.5})
        self.assertFalse(sent);d.point({'x':1,'y':0});self.assertEqual(sent[-1][1]['x'],639)
    def test_complete_input_contract(self):
        d,sent=self.display();d.perform({'kind':'combo','keys':['CTRL','S'],'duration':0});self.assertEqual([params['modifiers'] for method,params in sent],[2,2,2,0]);self.assertFalse(d.held)
        d.perform({'kind':'text','text':'日本語 text'});self.assertEqual(sent[-1][0],'Input.insertText');d.perform({'kind':'click','x':.2,'y':.3,'button':'right'});self.assertEqual(sent[-2][1]['buttons'],2)
        d.perform({'kind':'wheel','delta':120});self.assertEqual(sent[-1][1]['deltaY'],-120);d.perform({'kind':'drag','x':0,'y':0,'to_x':1,'to_y':1,'duration':0});self.assertEqual(sent[-1][1]['type'],'mouseReleased');self.assertFalse(any(method=='Runtime.evaluate' for method,params in sent))
    def test_drag_destination_validates_before_press(self):
        d,sent=self.display()
        with self.assertRaises(ValueError):d.perform({'kind':'drag','x':0,'y':0,'to_x':2,'to_y':1})
        self.assertFalse(sent)
    def test_png_rgb_rgba_and_features(self):
        with tempfile.TemporaryDirectory() as td:
            for color,raw in [(2,b'\0\xff\0\0\0\xff\0'),(6,b'\0\xff\0\0\xff\0\xff\0\xff')]:
                path=Path(td)/str(color);self.assertEqual(_png_bmp(png(2,1,color,raw),path),(2,1));self.assertEqual(path.read_bytes()[54:60],b'\0\0\xff\0\xff\0');self.assertEqual(len(image_features(path)),48*32*3)
    def test_png_all_filters(self):
        with tempfile.TemporaryDirectory() as td:
            path=Path(td)/'frame.bmp';_png_bmp(png(1,5,2,b'\0\xff\0\0\1\xff\0\0\2\0\0\0\3\x80\0\0\4\0\0\0'),path)
            for i in range(5):self.assertEqual(path.read_bytes()[54+i*4:57+i*4],b'\0\0\xff')
    def test_png_corruption_rejected(self):
        with tempfile.TemporaryDirectory() as td:
            raw=bytearray(png(1,1,2,b'\0\xff\0\0'));raw[-1]^=1
            with self.assertRaisesRegex(OSError,'BROWSER_PNG_CRC'):_png_bmp(raw,Path(td)/'bad.bmp')
            with self.assertRaisesRegex(OSError,'BROWSER_PNG_FILTER'):_png_bmp(png(1,1,2,b'\5\xff\0\0'),Path(td)/'bad2.bmp')
    def test_external_requests_rejected(self):
        d,sent=self.display();d.work=Path.cwd();records=[];d.record=records.append;d.cdp=SimpleNamespace(call=lambda *a,**kw:sent.append((a,kw)))
        d.on_event({'method':'Fetch.requestPaused','sessionId':'s','params':{'requestId':'r','request':{'url':'https://example.com/tracker'}}});self.assertEqual(sent[-1][0][0],'Fetch.failRequest');self.assertEqual(records[0]['method'],'FullAutoQA.external_request_blocked')
        d.on_event({'method':'Fetch.requestPaused','params':{'requestId':'local','request':{'url':'http://127.0.0.1:9000/game'}}});self.assertEqual(sent[-1][0][0],'Fetch.continueRequest')
    def test_stale_or_foreign_cdp_process_is_not_accepted(self):
        class ForeignProtocol:
            def __init__(self,*args):pass
            def call(self,method,*args,**kwargs):return {'processInfo':[{'type':'browser','id':99999}]} if method=='SystemInfo.getProcessInfo' else {'product':'UNIT_FOREIGN'}
            def close(self):pass
        with tempfile.TemporaryDirectory() as td:
            profile,process=self.config(td)
            with patch('browser_backend._CDP',ForeignProtocol):
                with self.assertRaisesRegex(OSError,'BROWSER_CDP_PROCESS_IDENTITY_MISMATCH'):select_browser_display(profile,td,process)
    def test_profile_lifecycle_protocol_double_not_browser_evidence(self):
        calls=[]
        class Protocol:
            error=None
            def __init__(self,url,callback):pass
            def call(self,method,params=None,session=None,**kw):
                calls.append(method)
                if method=='Browser.getVersion':return {'product':'UNIT_DOUBLE'}
                if method=='SystemInfo.getProcessInfo':return {'processInfo':[{'type':'browser','id':42}]}
                if method=='Target.createTarget':return {'targetId':'t'}
                if method=='Target.attachToTarget':return {'sessionId':'s'}
                if method=='Runtime.evaluate':return {'result':{'value':'complete' if params['expression']=='document.readyState' else True}}
                if method=='Browser.getWindowForTarget':return {'windowId':123,'bounds':{'width':2,'height':1}}
                if method=='Page.captureScreenshot':return {'data':base64.b64encode(png(2,1,2,b'\0\xff\0\0\0\xff\0')).decode()}
                return {}
            def close(self):self.error='CLOSED'
        with tempfile.TemporaryDirectory() as td:
            p,process=self.config(td)
            with patch('browser_backend._CDP',Protocol):
                d=select_browser_display(p,td,process);self.assertEqual(d.state()['backend'],'browser');self.assertFalse(d.state()['native_window']);self.assertTrue(d.focus()['verified']);self.assertEqual(d.capture(Path(td)/'frame.bmp')['dimensions'],[2,1]);d.on_event({'method':'Runtime.consoleAPICalled','params':{'type':'log'}});self.assertEqual(d.state()['console_event_count'],1);d.close();self.assertIn('Target.closeTarget',calls)

class ProtocolTests(unittest.TestCase):
    def test_websocket_real_loopback_mask_fragment_event_response(self):
        listener=socket.socket();listener.bind(('127.0.0.1',0));listener.listen();port=listener.getsockname()[1];events=[];errors=[]
        def server():
            try:
                with listener.accept()[0] as conn:
                    conn.settimeout(5)
                    def exact(n):
                        result=b''
                        while len(result)<n:
                            block=conn.recv(n-len(result))
                            if not block:raise OSError('closed')
                            result+=block
                        return result
                    header=b''
                    while not header.endswith(b'\r\n\r\n'):header+=exact(1)
                    key=next(line.split(b':',1)[1].strip() for line in header.split(b'\r\n') if line.startswith(b'Sec-WebSocket-Key:'));accept=base64.b64encode(hashlib.sha1(key+b'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest());conn.sendall(b'HTTP/1.1 101 Switching Protocols\r\nSec-WebSocket-Accept: '+accept+b'\r\n\r\n')
                    first,second=exact(2);self.assertTrue(second&128);size=second&127
                    if size==126:size=struct.unpack('!H',exact(2))[0]
                    mask=exact(4);data=exact(size);request=json.loads(bytes(v^mask[i%4] for i,v in enumerate(data)));event=json.dumps({'method':'Runtime.consoleAPICalled','params':{'type':'log'}}).encode();conn.sendall(bytes([129,len(event)])+event);response=json.dumps({'id':request['id'],'result':{'value':'socket protocol only'}}).encode();n=len(response)//2;conn.sendall(bytes([1,n])+response[:n]+bytes([128,len(response)-n])+response[n:]);conn.recv(1)
            except Exception as ex:errors.append(ex)
            finally:listener.close()
        thread=threading.Thread(target=server,daemon=True);thread.start();client=_CDP('ws://127.0.0.1:'+str(port)+'/devtools/unit',events.append)
        try:self.assertEqual(client.call('Unit.command',{'large':'x'*200})['value'],'socket protocol only');self.assertEqual(events[0]['method'],'Runtime.consoleAPICalled')
        finally:client.close();thread.join(6)
        self.assertFalse(thread.is_alive());self.assertFalse(errors)
if __name__=='__main__':unittest.main()
