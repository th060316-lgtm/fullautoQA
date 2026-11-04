"""Local browser transports: legacy Win32 GUI and explicit Chromium CDP.

Profiles select a preprovisioned runtime; no downloads or network service are
required. CDP exposes browser viewport/input/screenshots/console independently
from native Windows desktop focus. Unsupported transports never fall back.
"""
from __future__ import annotations

import ipaddress
import os
from pathlib import Path
from urllib.parse import unquote, urlparse
from urllib.request import url2pathname


def _loopback_host(host):
    if not host:
        return False
    host = host.strip("[]").lower()
    if host == "localhost":
        return True
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


def validate_browser_target(target, work):
    if not isinstance(target, str) or not target.strip():
        raise OSError("BROWSER_TARGET_MISSING")
    text = target.strip()
    parsed = urlparse(text)
    root = Path(work).resolve()
    if not parsed.scheme:
        resolved = (root / unquote(text)).resolve()
        try:
            resolved.relative_to(root)
        except ValueError:
            raise OSError("BROWSER_FILE_TARGET_OUTSIDE_WORK")
        if not resolved.exists():
            raise OSError("BROWSER_FILE_TARGET_MISSING")
        return {"scheme": "file", "target": target, "resolved": str(resolved)}
    if parsed.scheme == "file":
        if parsed.netloc:
            raise OSError("BROWSER_FILE_HOST_FORBIDDEN")
        raw = url2pathname(unquote(parsed.path or ""))
        # Windows file URLs can encode /C:/...
        if os.name == "nt" and len(raw) >= 3 and raw[0] in "/\\" and raw[2] == ":":
            raw = raw[1:]
        path = Path(raw)
        if not path.is_absolute():
            path = root / path
        resolved = path.resolve()
        try:
            resolved.relative_to(root)
        except ValueError:
            raise OSError("BROWSER_FILE_TARGET_OUTSIDE_WORK")
        if not resolved.exists():
            raise OSError("BROWSER_FILE_TARGET_MISSING")
        return {"scheme": "file", "target": target, "resolved": str(resolved)}
    if parsed.scheme in ("http", "https") and _loopback_host(parsed.hostname):
        return {"scheme": parsed.scheme, "target": target, "host": parsed.hostname,
                "port": parsed.port}
    raise OSError("BROWSER_EXTERNAL_NETWORK_FORBIDDEN")


def validate_browser_profile(profile, work, launch_args=None):
    display = profile.get("display") or {}
    target = display.get("target") or display.get("url") or display.get("start_url")
    result = validate_browser_target(target, work)
    # Validate the actual expanded launch arguments when the caller has them.
    # This prevents a tool/profile token from expanding into an external URL after
    # an earlier check of only the literal profile text.
    args = launch_args
    if args is None:
        launch = profile.get("launch") or {}
        args = list(launch.get("argv", [])) + list(launch.get("extra_args", []))
    for arg in args:
        text = str(arg)
        if "://" in text:
            validate_browser_target(text, work)
    return result


class BrowserDisplay:
    """Real Windows GUI binding to an already-launched local browser process."""

    def __init__(self, profile, work, process):
        if os.name != "nt":
            raise OSError("BROWSER_WINDOWS_DESKTOP_REQUIRED")
        self.profile = profile
        self.work = Path(work)
        self.target = validate_browser_profile(profile, work)
        from windows import Desktop, child_pids
        self._desktop = Desktop()
        self._desktop.find(child_pids(process.pid))

    def focus(self):
        self._desktop.focus()
        state = self._desktop.state()
        if not state.get("focused"):
            raise OSError("FOCUS_NOT_VERIFIED")
        return {"verified": True, "window": state, "method": "SendInput/BitBlt",
                "backend": "browser"}

    def perform(self, item):
        return self._desktop.perform(item)

    def capture(self, path):
        return self._desktop.capture(path)

    def release(self):
        return self._desktop.release()

    def close(self):
        return self.release()

    def state(self):
        state = self._desktop.state()
        state["backend"] = "browser"
        state["transport"] = "windows"
        state["capabilities"] = self.capabilities()
        state["browser_target"] = self.target
        return state

    def capabilities(self):
        return {"browser":True,"viewport":False,"input":True,"screenshot":True,"console":False,"process":True,"native_window":True,"engine":"Win32 GUI process binding"}

    def windows(self, pids):
        return self._desktop.windows(pids)


def select_browser_display(profile, work, process):
    transport = profile.get("display", {}).get("transport", "windows")
    if transport == "windows":
        return BrowserDisplay(profile, work, process)
    if transport == "cdp":
        return CDPBrowserDisplay(profile, work, process)
    raise OSError("BROWSER_TRANSPORT_UNSUPPORTED:" + str(transport))

# Explicit Chromium CDP transport: standard library only, no runtime downloads.
import base64
import hashlib
import json
import math
import socket
import struct
import threading
import time
import zlib
from collections import deque


class _CDP:
    """Local WebSocket protocol client with a dedicated CDP event reader."""
    def __init__(self, url, callback, timeout=15):
        parsed = urlparse(url)
        if parsed.scheme != 'ws' or not _loopback_host(parsed.hostname) or parsed.username or parsed.password:
            raise OSError('BROWSER_CDP_ENDPOINT_FORBIDDEN')
        self.sock = socket.create_connection((parsed.hostname, parsed.port), timeout)
        self.condition = threading.Condition()
        self.send_lock = threading.Lock()
        self.sequence, self.pending, self.responses = 0, set(), {}
        self.closed, self.error, self.callback = False, None, callback
        try:
            self.sock.settimeout(timeout)
            key = base64.b64encode(os.urandom(16)).decode()
            request = ('GET '+parsed.path+' HTTP/1.1\r\nHost: '+parsed.netloc+'\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: '+key+'\r\nSec-WebSocket-Version: 13\r\n\r\n')
            self.sock.sendall(request.encode('ascii'))
            header = bytearray()
            while not header.endswith(b'\r\n\r\n'):
                header.extend(self.exact(1))
                if len(header) > 16384:
                    raise OSError('BROWSER_CDP_HANDSHAKE_OVERSIZE')
            lines = header.decode('ascii').split('\r\n')
            fields = {line.split(':',1)[0].lower():line.split(':',1)[1].strip() for line in lines[1:] if ':' in line}
            expected = base64.b64encode(hashlib.sha1((key+'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
            if ' 101 ' not in lines[0] or fields.get('sec-websocket-accept') != expected:
                raise OSError('BROWSER_CDP_HANDSHAKE_FAILED')
        except Exception:
            self.sock.close()
            raise
        self.sock.settimeout(None)
        self.reader = threading.Thread(target=self.read_loop, daemon=True)
        self.reader.start()

    def exact(self, size):
        data = bytearray()
        while len(data) < size:
            block = self.sock.recv(size-len(data))
            if not block:
                raise OSError('BROWSER_CDP_DISCONNECTED')
            data.extend(block)
        return bytes(data)

    def send(self, data, opcode=1):
        size, mask = len(data), os.urandom(4)
        prefix = bytes([128 | opcode, 128 | (size if size < 126 else 126 if size < 65536 else 127)])
        if size >= 126:
            prefix += struct.pack('!H' if size < 65536 else '!Q', size)
        with self.send_lock:
            self.sock.sendall(prefix+mask+bytes(v ^ mask[i%4] for i,v in enumerate(data)))

    def call(self, method, params=None, session=None, wait=True, timeout=15):
        with self.condition:
            self.sequence += 1
            number = self.sequence
            if wait:
                self.pending.add(number)
        message = {'id':number, 'method':method, 'params':params or {}}
        if session:
            message['sessionId'] = session
        try:
            self.send(json.dumps(message).encode())
            if not wait:
                return
            deadline = time.monotonic()+timeout
            with self.condition:
                while number not in self.responses:
                    if self.closed or self.error:
                        raise OSError('BROWSER_CDP_READER_FAILED:'+str(self.error))
                    remaining = deadline-time.monotonic()
                    if remaining <= 0:
                        raise TimeoutError('BROWSER_CDP_TIMEOUT:'+method)
                    self.condition.wait(remaining)
                response = self.responses.pop(number)
            if 'error' in response:
                raise OSError('BROWSER_CDP_ERROR:'+method+':'+str(response['error']))
            return response.get('result', {})
        finally:
            with self.condition:
                self.pending.discard(number)

    def read_loop(self):
        try:
            fragments = bytearray()
            while not self.closed:
                first, second = self.exact(2)
                opcode, size = first & 15, second & 127
                if size == 126:
                    size = struct.unpack('!H',self.exact(2))[0]
                elif size == 127:
                    size = struct.unpack('!Q',self.exact(8))[0]
                if second & 128 or size > 64*1024*1024:
                    raise OSError('BROWSER_CDP_FRAME_INVALID')
                data = self.exact(size)
                if opcode == 8:
                    raise OSError('BROWSER_CDP_CLOSED')
                if opcode == 9:
                    self.send(data,10)
                    continue
                if opcode == 10:
                    continue
                if opcode not in (0,1):
                    raise OSError('BROWSER_CDP_OPCODE_UNSUPPORTED')
                fragments.extend(data)
                if len(fragments) > 64*1024*1024:
                    raise OSError('BROWSER_CDP_MESSAGE_OVERSIZE')
                if not first & 128:
                    continue
                message = json.loads(fragments)
                fragments.clear()
                if 'id' in message:
                    with self.condition:
                        if message['id'] in self.pending:
                            self.responses[message['id']] = message
                        self.condition.notify_all()
                else:
                    self.callback(message)
        except Exception as ex:
            with self.condition:
                self.error = repr(ex)
                self.condition.notify_all()

    def close(self):
        self.closed = True
        try:
            self.sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        self.sock.close()
        self.reader.join(timeout=2)


def _png_bmp(raw, path):
    """Decode Chromium RGB/RGBA PNG to the existing 24-bit BMP contract."""
    if raw[:8] != b'\x89PNG\r\n\x1a\n':
        raise OSError('BROWSER_PNG_REQUIRED')
    position, compressed, channels = 8, bytearray(), None
    while position < len(raw):
        if position+12 > len(raw):
            raise OSError('BROWSER_PNG_TRUNCATED')
        size = struct.unpack_from('!I',raw,position)[0]
        kind = raw[position+4:position+8]
        data = raw[position+8:position+8+size]
        if position+size+12 > len(raw):
            raise OSError('BROWSER_PNG_TRUNCATED')
        if zlib.crc32(kind+data) & 0xffffffff != struct.unpack_from('!I',raw,position+8+size)[0]:
            raise OSError('BROWSER_PNG_CRC')
        if kind == b'IHDR':
            width,height,depth,color,comp,filt,interlace = struct.unpack('!IIBBBBB',data)
            if depth != 8 or color not in (2,6) or comp or filt or interlace or not 0 < width <= 8192 or not 0 < height <= 8192:
                raise OSError('BROWSER_PNG_FORMAT')
            channels = 3 if color == 2 else 4
        elif kind == b'IDAT':
            compressed.extend(data)
        elif kind == b'IEND':
            break
        position += size+12
    if not channels:
        raise OSError('BROWSER_PNG_IHDR_REQUIRED')
    size = (width*channels+1)*height
    decoder = zlib.decompressobj()
    decoded = decoder.decompress(compressed,size+1)
    if len(decoded) != size or not decoder.eof:
        raise OSError('BROWSER_PNG_SIZE')
    stride = (width*3+3) & ~3
    pixels, previous = bytearray(stride*height), bytearray(width*channels)
    for y in range(height):
        at = y*(width*channels+1)
        mode = decoded[at]
        row = bytearray(decoded[at+1:at+1+width*channels])
        for x in range(len(row)):
            a,b,c = (row[x-channels] if x >= channels else 0),previous[x],(previous[x-channels] if x >= channels else 0)
            if mode == 0:
                predictor = 0
            elif mode == 1:
                predictor = a
            elif mode == 2:
                predictor = b
            elif mode == 3:
                predictor = (a+b)//2
            elif mode == 4:
                estimate = a+b-c
                distances = [abs(estimate-v) for v in (a,b,c)]
                predictor = (a,b,c)[distances.index(min(distances))]
            else:
                raise OSError('BROWSER_PNG_FILTER')
            row[x] = (row[x]+predictor) & 255
        at = (height-y-1)*stride
        for x in range(width):
            pixels[at+x*3:at+x*3+3] = row[x*channels:x*channels+3][::-1]
        previous = row
    header = struct.pack('<2sIHHI',b'BM',54+len(pixels),0,0,54)+struct.pack('<IiiHHIIiiII',40,width,height,1,24,0,len(pixels),0,0,0,0)
    Path(path).parent.mkdir(parents=True,exist_ok=True)
    Path(path).write_bytes(header+pixels)
    return width,height


class CDPBrowserDisplay:
    """Explicit local Chromium-family viewport backend, including headless.

    Protocol input is real browser input. No game state is mutated via JS.
    A viewport focus claim is distinct from native Windows desktop focus.
    """
    def __init__(self, profile, work, process):
        self.profile,self.work,self.process = profile,Path(work).resolve(),process
        self.target = validate_browser_profile(profile,work)
        cfg = profile['display']
        self.lock,self.event_lock = threading.RLock(),threading.Lock()
        self.events,self.event_count = deque(maxlen=256),0
        self.held,self.closed,self.session = set(),False,None
        runtime = cfg.get('runtime') or {}
        if runtime.get('engine') != 'chromium-cdp':
            raise OSError('BROWSER_RUNTIME_ENGINE_REQUIRED')
        executable = Path(runtime.get('executable') or '')
        if not executable.is_absolute() or not executable.is_file():
            raise OSError('BROWSER_RUNTIME_EXECUTABLE_REQUIRED')
        if not isinstance(process.args,(list,tuple)) or Path(process.args[0]).resolve() != executable.resolve():
            raise OSError('BROWSER_RUNTIME_PROCESS_MISMATCH')
        digest = hashlib.sha256(executable.read_bytes()).hexdigest()
        if runtime.get('sha256') != digest:
            raise OSError('BROWSER_RUNTIME_HASH_MISMATCH')
        self.runtime = {'engine':runtime['engine'],'executable':str(executable),'sha256':digest,'pid':process.pid,'provenance':runtime.get('provenance')}
        endpoint = (self.work/str(cfg.get('endpoint',''))).resolve()
        try:
            endpoint.relative_to(self.work)
        except ValueError:
            raise OSError('BROWSER_CDP_ENDPOINT_OUTSIDE_WORK')
        if endpoint.name != 'DevToolsActivePort':
            raise OSError('BROWSER_CDP_ACTIVE_PORT_REQUIRED')
        argv = [str(arg) for arg in process.args]
        if argv[-1] != 'about:blank' or any(not arg.startswith('--') and arg != 'about:blank' for arg in argv[1:]):
            raise OSError('BROWSER_CDP_BLANK_LAUNCH_REQUIRED')
        if '--remote-debugging-port=0' not in argv or '--user-data-dir='+str(endpoint.parent) not in argv:
            raise OSError('BROWSER_CDP_ISOLATED_LAUNCH_REQUIRED')
        rows = endpoint.read_text().splitlines()
        if len(rows) != 2 or not rows[0].isdigit() or not rows[1].startswith('/devtools/browser/'):
            raise OSError('BROWSER_CDP_ACTIVE_PORT_INVALID')
        self.console_path = self.work/'browser_console.jsonl'
        self.console_path.write_text('',encoding='utf-8')
        self.cdp = _CDP('ws://127.0.0.1:'+rows[0]+rows[1],self.on_event)
        try:
            self.runtime['version'] = self.cdp.call('Browser.getVersion')
            self.target_id = self.cdp.call('Target.createTarget',{'url':'about:blank'})['targetId']
            self.session = self.cdp.call('Target.attachToTarget',{'targetId':self.target_id,'flatten':True})['sessionId']
            for domain in ('Runtime','Page','Network'):
                self.call(domain+'.enable')
            self.call('Fetch.enable',{'patterns':[{'urlPattern':'*','requestStage':'Request'}]})
            viewport = cfg.get('viewport')
            if not isinstance(viewport,dict):
                raise OSError('BROWSER_VIEWPORT_CONTRACT_REQUIRED')
            width,height = viewport.get('width'),viewport.get('height')
            if any(isinstance(v,bool) or not isinstance(v,int) or not 1 <= v <= 8192 for v in (width,height)):
                raise OSError('BROWSER_VIEWPORT_INVALID')
            self.width,self.height = width,height
            self.call('Emulation.setDeviceMetricsOverride',{'width':width,'height':height,'deviceScaleFactor':1,'mobile':False})
            url = Path(self.target['resolved']).as_uri() if self.target['scheme']=='file' else self.target['target']
            result = self.call('Page.navigate',{'url':url})
            if result.get('errorText'):
                raise OSError('BROWSER_NAVIGATION_FAILED:'+result['errorText'])
            deadline = time.monotonic()+profile.get('startup_timeout',30)
            while self.evaluate('document.readyState') != 'complete':
                if process.poll() is not None or time.monotonic() >= deadline:
                    raise OSError('BROWSER_NAVIGATION_TIMEOUT')
                time.sleep(.03)
            self.window_info = self.cdp.call('Browser.getWindowForTarget',{'targetId':self.target_id})
        except Exception:
            self.cdp.close()
            raise

    def call(self, method, params=None):
        return self.cdp.call(method,params,self.session)

    def evaluate(self, expression):
        result = self.call('Runtime.evaluate',{'expression':expression,'returnByValue':True})
        if result.get('exceptionDetails'):
            raise OSError('BROWSER_OBSERVATION_EVALUATION_FAILED')
        return result.get('result',{}).get('value')

    def on_event(self, event):
        if event.get('method') == 'Fetch.requestPaused':
            params = event['params']
            url = params['request']['url']
            try:
                if urlparse(url).scheme not in ('data','blob','about'):
                    validate_browser_target(url,self.work)
                method,extra = 'Fetch.continueRequest',{}
            except (OSError,ValueError):
                method,extra = 'Fetch.failRequest',{'errorReason':'BlockedByClient'}
                self.record({'method':'FullAutoQA.external_request_blocked','params':{'url':url}})
            # The reader must not wait on itself for an interception response.
            self.cdp.call(method,{'requestId':params['requestId'],**extra},event.get('sessionId'),wait=False)
        if event.get('method') in ('Runtime.consoleAPICalled','Runtime.exceptionThrown','Network.loadingFailed','Network.webSocketCreated','Page.frameNavigated'):
            self.record(event)

    def record(self, event):
        row = {'monotonic':time.monotonic(),**event}
        with self.event_lock:
            self.event_count += 1
            self.events.append(row)
            with self.console_path.open('a',encoding='utf-8') as stream:
                stream.write(json.dumps(row,ensure_ascii=False)+'\n')

    def capabilities(self):
        return {'browser':True,'viewport':True,'input':True,'screenshot':True,'console':True,'process':True,'native_window':False,'engine':'chromium-cdp',
                'supported_inputs':['key','hold','combo','text','wait','click','double_click','move','drag','wheel'],
                'network_policy':'Fetch-intercepted requests restricted to work files/loopback; workers, WebSocket, WebRTC and browser background traffic not certified'}

    def focus(self):
        with self.lock:
            self.call('Page.bringToFront')
            if not self.evaluate('document.hasFocus()'):
                raise OSError('BROWSER_VIEWPORT_FOCUS_NOT_VERIFIED')
            return {'verified':True,'method':'CDP Page.bringToFront/document.hasFocus','backend':'browser','transport':'cdp','native_window':False,'dimensions':[self.width,self.height]}

    def state(self):
        with self.lock:
            exists = not self.closed and self.process.poll() is None and self.cdp.error is None
            title = self.evaluate('document.title') if exists else None
            focused = bool(self.evaluate('document.hasFocus()')) if exists else False
            with self.event_lock:
                events,count = list(self.events),self.event_count
            return {'exists':exists,'focused':focused,'backend':'browser','transport':'cdp','native_window':False,'viewport':True,'rect':[0,0,self.width,self.height],
                    'title':title,'window':self.window_info,'browser_target':self.target,'runtime':self.runtime,'console':events,'console_event_count':count,'console_file':str(self.console_path),'capabilities':self.capabilities()}

    def key(self, name, up=False):
        special = {'ENTER':('Enter','Enter',13),'ESC':('Escape','Escape',27),'SPACE':(' ','Space',32),'TAB':('Tab','Tab',9),'SHIFT':('Shift','ShiftLeft',16),'CTRL':('Control','ControlLeft',17),
                   'ALT':('Alt','AltLeft',18),'META':('Meta','MetaLeft',91),'BACKSPACE':('Backspace','Backspace',8),'DELETE':('Delete','Delete',46),'HOME':('Home','Home',36),'END':('End','End',35),
                   'PAGEUP':('PageUp','PageUp',33),'PAGEDOWN':('PageDown','PageDown',34),'LEFT':('ArrowLeft','ArrowLeft',37),'UP':('ArrowUp','ArrowUp',38),'RIGHT':('ArrowRight','ArrowRight',39),'DOWN':('ArrowDown','ArrowDown',40)}
        token = name.upper()
        if token in special:
            key,code,vk = special[token]
        elif len(name)==1 and name.isascii() and name.isalnum():
            key,code,vk = name.lower(),('Key'+token if name.isalpha() else 'Digit'+name),ord(token)
        elif token.startswith('F') and token[1:].isdigit() and 1 <= int(token[1:]) <= 12:
            key,code,vk = token,token,111+int(token[1:])
        else:
            raise ValueError('BROWSER_INPUT_KEY_UNSUPPORTED:'+name)
        held = {value.upper() for value in self.held}
        held.discard(token) if up else held.add(token)
        modifiers = sum(flag for name,flag in [('ALT',1),('CTRL',2),('META',4),('SHIFT',8)] if name in held)
        self.call('Input.dispatchKeyEvent',{'type':'keyUp' if up else 'keyDown','key':key,'code':code,'windowsVirtualKeyCode':vk,'nativeVirtualKeyCode':vk,'modifiers':modifiers})
        self.held.discard(name) if up else self.held.add(name)

    def point(self, item, event='mouseMoved', button='none', count=0, buttons=0):
        x,y = item.get('x'),item.get('y')
        if any(isinstance(v,bool) or not isinstance(v,(int,float)) or not math.isfinite(v) or not 0 <= v <= 1 for v in (x,y)):
            raise ValueError('BROWSER_INPUT_COORDINATE_INVALID')
        x,y = round(x*(self.width-1)),round(y*(self.height-1))
        self.call('Input.dispatchMouseEvent',{'type':event,'x':x,'y':y,'button':button,'clickCount':count,'buttons':buttons})
        return x,y

    def perform(self, item):
        with self.lock:
            kind,duration = item['kind'],item.get('duration',.04)
            if isinstance(duration,bool) or not isinstance(duration,(int,float)) or not math.isfinite(duration) or not 0 <= duration <= 3600:
                raise ValueError('BROWSER_INPUT_DURATION_INVALID')
            if kind in ('key','hold'):
                self.key(item['key'])
                try:
                    time.sleep(duration)
                finally:
                    self.key(item['key'],True)
            elif kind == 'combo':
                pressed = []
                try:
                    for name in item['keys']:
                        self.key(name)
                        pressed.append(name)
                    time.sleep(duration)
                finally:
                    for name in reversed(pressed):
                        self.key(name,True)
            elif kind == 'text':
                if not isinstance(item.get('text'),str):
                    raise ValueError('BROWSER_INPUT_TEXT_INVALID')
                self.call('Input.insertText',{'text':item['text']})
            elif kind in ('click','double_click'):
                button = item.get('button','left')
                if button not in ('left','right','middle'):
                    raise ValueError('BROWSER_INPUT_BUTTON_INVALID')
                for count in range(1,3 if kind=='double_click' else 2):
                    self.point(item,'mousePressed',button,count,{'left':1,'right':2,'middle':4}[button])
                    self.point(item,'mouseReleased',button,count)
            elif kind == 'move':
                return self.point(item)
            elif kind == 'drag':
                target = {'x':item['to_x'],'y':item['to_y']}
                if any(isinstance(v,bool) or not isinstance(v,(int,float)) or not math.isfinite(v) or not 0 <= v <= 1 for v in target.values()):
                    raise ValueError('BROWSER_INPUT_COORDINATE_INVALID')
                self.point(item,'mousePressed','left',1,1)
                try:
                    for step in range(1,11):
                        self.point({'x':item['x']+(item['to_x']-item['x'])*step/10,'y':item['y']+(item['to_y']-item['y'])*step/10},buttons=1)
                        time.sleep(duration/10)
                finally:
                    self.point(target,'mouseReleased','left',1)
            elif kind == 'wheel':
                delta = item.get('delta',120)
                if isinstance(delta,bool) or not isinstance(delta,(int,float)) or not math.isfinite(delta):
                    raise ValueError('BROWSER_INPUT_WHEEL_INVALID')
                x,y = self.point({'x':item.get('x',.5),'y':item.get('y',.5)})
                self.call('Input.dispatchMouseEvent',{'type':'mouseWheel','x':x,'y':y,'deltaX':0,'deltaY':-delta})
            elif kind == 'wait':
                time.sleep(duration)
            else:
                raise ValueError('BROWSER_INPUT_NOT_IMPLEMENTED:'+kind)

    def capture(self, path):
        with self.lock:
            data = self.call('Page.captureScreenshot',{'format':'png','captureBeyondViewport':False})['data']
            width,height = _png_bmp(base64.b64decode(data,validate=True),path)
            if (width,height) != (self.width,self.height):
                raise OSError('BROWSER_CAPTURE_VIEWPORT_MISMATCH')
            return {'dimensions':[width,height],'pixels':width*height,'source':'CDP real browser viewport','backend':'browser','transport':'cdp'}

    def windows(self, pids):
        return [self.window_info] if self.process.pid in pids else []

    def release(self):
        with self.lock:
            for name in list(self.held):
                self.key(name,True)

    def close(self):
        if not self.closed:
            try:
                self.release()
                self.cdp.call('Target.closeTarget',{'targetId':self.target_id})
            finally:
                self.closed = True
                self.cdp.close()
