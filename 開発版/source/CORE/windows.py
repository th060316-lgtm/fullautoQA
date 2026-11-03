"""Native, per-process Windows automation. No driver, service or registry writes."""
import os,time,ctypes as C,struct,subprocess,re
from ctypes import wintypes as W
from pathlib import Path
if os.name=='nt':
    U=C.WinDLL('user32',use_last_error=True);G=C.WinDLL('gdi32',use_last_error=True);K=C.WinDLL('kernel32',use_last_error=True)
    K.CloseHandle.argtypes=[W.HANDLE]
    K.SetErrorMode(0x0001|0x0002|0x8000)
    U.SetProcessDPIAware()
    U.GetKeyboardLayout.argtypes=[W.DWORD];U.GetKeyboardLayout.restype=W.HANDLE
    U.MapVirtualKeyExW.argtypes=[W.UINT,W.UINT,W.HANDLE];U.MapVirtualKeyExW.restype=W.UINT
    U.GetDesktopWindow.restype=W.HWND
    U.GetForegroundWindow.restype=W.HWND
    for _name in ('IsWindow','IsWindowVisible','IsIconic','SetForegroundWindow'):
        getattr(U,_name).argtypes=[W.HWND]
    U.ShowWindow.argtypes=[W.HWND,C.c_int]
    U.GetWindowRect.argtypes=[W.HWND,C.POINTER(W.RECT)]
    U.GetClientRect.argtypes=[W.HWND,C.POINTER(W.RECT)]
    U.ClientToScreen.argtypes=[W.HWND,C.POINTER(W.POINT)]
    U.GetWindowThreadProcessId.argtypes=[W.HWND,C.POINTER(W.DWORD)]
    U.GetWindowTextW.argtypes=[W.HWND,W.LPWSTR,C.c_int]
    class MOUSEINPUT(C.Structure):_fields_=[('dx',W.LONG),('dy',W.LONG),('mouseData',W.DWORD),('dwFlags',W.DWORD),('time',W.DWORD),('dwExtraInfo',C.c_size_t)]
    class KEYBDINPUT(C.Structure):_fields_=[('wVk',W.WORD),('wScan',W.WORD),('dwFlags',W.DWORD),('time',W.DWORD),('dwExtraInfo',C.c_size_t)]
    class HARDWAREINPUT(C.Structure):_fields_=[('uMsg',W.DWORD),('wParamL',W.WORD),('wParamH',W.WORD)]
    class UNION(C.Union):_fields_=[('mi',MOUSEINPUT),('ki',KEYBDINPUT),('hi',HARDWAREINPUT)]
    class INPUT(C.Structure):_anonymous_=('u',);_fields_=[('type',W.DWORD),('u',UNION)]
    U.SendInput.argtypes=[W.UINT,C.POINTER(INPUT),C.c_int];U.SendInput.restype=W.UINT
    U.GetDC.restype=W.HDC;G.CreateCompatibleDC.restype=W.HDC;G.CreateCompatibleBitmap.restype=W.HBITMAP;G.SelectObject.restype=W.HANDLE
    U.GetDC.argtypes=[W.HWND];U.ReleaseDC.argtypes=[W.HWND,W.HDC]
    G.CreateCompatibleDC.argtypes=[W.HDC];G.CreateCompatibleBitmap.argtypes=[W.HDC,C.c_int,C.c_int]
    G.SelectObject.argtypes=[W.HDC,W.HANDLE];G.DeleteObject.argtypes=[W.HANDLE];G.DeleteDC.argtypes=[W.HDC]
    G.BitBlt.argtypes=[W.HDC,C.c_int,C.c_int,C.c_int,C.c_int,W.HDC,C.c_int,C.c_int,W.DWORD]
    G.GetDIBits.argtypes=[W.HDC,W.HBITMAP,W.UINT,W.UINT,C.c_void_p,C.c_void_p,W.UINT]
KEYS={'ENTER':13,'ESC':27,'SPACE':32,'TAB':9,'SHIFT':16,'CTRL':17,'ALT':18,'LEFT':37,'UP':38,'RIGHT':39,'DOWN':40,'F5':116,'F9':120,'BACKSPACE':8}
def vk(s):
    s=s.upper()
    if s in KEYS:return KEYS[s]
    if re.fullmatch(r'F(?:[1-9]|1[0-9]|2[0-4])',s):return 0x70+int(s[1:])-1
    if len(s)==1:return ord(s)
    raise ValueError('UNKNOWN_KEY:'+s)

class Desktop:
    def __init__(self):
        if os.name!='nt':raise OSError('WINDOWS_DESKTOP_REQUIRED')
        self.held=set();self.hwnd=None
    def windows(self,pids):
        found=[]
        @C.WINFUNCTYPE(W.BOOL,W.HWND,W.LPARAM)
        def cb(h,l):
            pid=W.DWORD();U.GetWindowThreadProcessId(h,C.byref(pid))
            if pid.value in pids and U.IsWindowVisible(h):
                text=C.create_unicode_buffer(1024);U.GetWindowTextW(h,text,1024);found.append((h,text.value,pid.value))
            return True
        U.EnumWindows(cb,0);return found
    def find(self,pids,timeout=20):
        deadline=time.monotonic()+timeout
        while time.monotonic()<deadline:
            wins=self.windows(pids)
            if wins:self.hwnd=wins[0][0];self.focus();return self.state()
            time.sleep(.1)
        raise TimeoutError('WINDOW_STARTUP_TIMEOUT')
    def focus(self):
        if self.hwnd:
            U.ShowWindow(self.hwnd,9);U.SetForegroundWindow(self.hwnd)
    def state(self):
        if not self.hwnd or not U.IsWindow(self.hwnd):return {'exists':False}
        r=W.RECT();U.GetWindowRect(self.hwnd,C.byref(r));t=C.create_unicode_buffer(1024);U.GetWindowTextW(self.hwnd,t,1024)
        return {'exists':True,'title':t.value,'focused':U.GetForegroundWindow()==self.hwnd,'minimized':bool(U.IsIconic(self.hwnd)),'rect':[r.left,r.top,r.right,r.bottom]}
    def send(self,item):
        if U.SendInput(1,C.byref(item),C.sizeof(INPUT))!=1:raise OSError('SENDINPUT_FAILED_OR_UIPI')
    def key(self,k,up=False):
        n=vk(k)
        thread=U.GetWindowThreadProcessId(self.hwnd,None) if self.hwnd else 0
        scan=U.MapVirtualKeyExW(n,4,U.GetKeyboardLayout(thread))
        if not scan:raise OSError('KEY_SCAN_CODE_UNAVAILABLE:'+k)
        flags=8 | (2 if up else 0) | (1 if scan & 0xff00 else 0)
        i=INPUT(type=1);i.ki=KEYBDINPUT(0,scan & 0xff,flags,0,0);self.send(i)
        if up:self.held.discard(k)
        else:self.held.add(k)
    def mouse(self,flag,data=0):
        i=INPUT(type=0);i.mi=MOUSEINPUT(0,0,data,flag,0,0);self.send(i)
    def point(self,x,y):
        if not self.hwnd:raise OSError('NO_WINDOW')
        r=W.RECT();U.GetClientRect(self.hwnd,C.byref(r));p=W.POINT(round(x*(r.right-r.left)),round(y*(r.bottom-r.top)));U.ClientToScreen(self.hwnd,C.byref(p));U.SetCursorPos(p.x,p.y)
    def perform(self,item):
        kind=item['kind'];duration=item.get('duration',.08)
        if kind in ('key','hold'):
            k=item['key'];self.key(k)
            try:time.sleep(duration)
            finally:self.key(k,True)
        elif kind=='combo':
            ks=item['keys']
            try:
                for k in ks:self.key(k)
                time.sleep(duration)
            finally:
                for k in reversed(ks):self.key(k,True)
        elif kind=='text':
            b=item['text'].encode('utf-16-le')
            for n in struct.unpack('<'+'H'*(len(b)//2),b):
                for flag in (4,6):
                    i=INPUT(type=1);i.ki=KEYBDINPUT(0,n,flag,0,0);self.send(i)
        elif kind=='wait':time.sleep(duration)
        elif kind in ('click','double_click','move','drag'):
            self.point(item.get('x',.5),item.get('y',.5))
            if kind in ('click','double_click'):
                for _ in range(2 if kind=='double_click' else 1):
                    down,up=(8,16) if item.get('button')=='right' else (2,4);self.mouse(down);self.mouse(up);time.sleep(.07)
            elif kind=='drag':
                self.mouse(2)
                try:
                    for j in range(1,11):
                        self.point(item['x']+(item['to_x']-item['x'])*j/10,item['y']+(item['to_y']-item['y'])*j/10);time.sleep(duration/10)
                finally:self.mouse(4)
        elif kind=='wheel':self.mouse(0x800,item.get('delta',120)&0xffffffff)
        else:raise ValueError('UNSUPPORTED_INPUT')
    def release(self):
        for k in list(self.held):
            try:self.key(k,True)
            except OSError:pass
        self.mouse(4);self.mouse(16)
    def capture(self,path):
        st=self.state()
        if not st['exists']:raise OSError('WINDOW_MISSING')
        x,y,right,bottom=st['rect'];w,h=right-x,bottom-y
        if w<=0 or h<=0:raise OSError('INVALID_CAPTURE_DIMENSIONS')
        src=U.GetDC(0);dc=G.CreateCompatibleDC(src);bmp=G.CreateCompatibleBitmap(src,w,h);old=G.SelectObject(dc,bmp)
        try:
            if not G.BitBlt(dc,0,0,w,h,src,x,y,0x40cc0020):raise OSError('BITBLT_FAILED')
            stride=((w*3+3)//4)*4;size=stride*h;buf=C.create_string_buffer(size)
            info=C.create_string_buffer(struct.pack('<IiiHHIIiiII',40,w,h,1,24,0,size,0,0,0,0)+b'\0'*16)
            if not G.GetDIBits(dc,bmp,0,h,buf,info,0):raise OSError('GETDIBITS_FAILED')
            Path(path).write_bytes(struct.pack('<2sIHHI',b'BM',54+size,0,0,54)+info.raw[:40]+buf.raw)
        finally:G.SelectObject(dc,old);G.DeleteObject(bmp);G.DeleteDC(dc);U.ReleaseDC(0,src)
        return path

def process_metrics(pid):
    if os.name!='nt':return {}
    class PMC(C.Structure):_fields_=[('cb',W.DWORD),('PageFaultCount',W.DWORD)]+[(x,C.c_size_t) for x in ('PeakWorkingSetSize','WorkingSetSize','QuotaPeakPagedPoolUsage','QuotaPagedPoolUsage','QuotaPeakNonPagedPoolUsage','QuotaNonPagedPoolUsage','PagefileUsage','PeakPagefileUsage')]
    class IO(C.Structure):_fields_=[(x,C.c_ulonglong) for x in ('read_operations','write_operations','other_operations','read_bytes','write_bytes','other_bytes')]
    K.OpenProcess.restype=W.HANDLE;K.OpenProcess.argtypes=[W.DWORD,W.BOOL,W.DWORD];K.CloseHandle.argtypes=[W.HANDLE]
    h=K.OpenProcess(0x410,False,pid)
    if not h:return {'pid':pid,'unavailable':True}
    try:
        m=PMC();m.cb=C.sizeof(m);ps=C.WinDLL('psapi');ps.GetProcessMemoryInfo.argtypes=[W.HANDLE,C.c_void_p,W.DWORD]
        ps.GetProcessMemoryInfo(h,C.byref(m),m.cb);count=W.DWORD();K.GetProcessHandleCount.argtypes=[W.HANDLE,C.POINTER(W.DWORD)];K.GetProcessHandleCount(h,C.byref(count))
        create=W.FILETIME();exit_=W.FILETIME();kernel=W.FILETIME();user=W.FILETIME();K.GetProcessTimes.argtypes=[W.HANDLE,C.c_void_p,C.c_void_p,C.c_void_p,C.c_void_p];K.GetProcessTimes(h,C.byref(create),C.byref(exit_),C.byref(kernel),C.byref(user))
        ticks=lambda t:(t.dwHighDateTime<<32)|t.dwLowDateTime
        return {'pid':pid,'ram':m.WorkingSetSize,'handles':count.value,'cpu_seconds':(ticks(kernel)+ticks(user))/1e7}
    finally:K.CloseHandle(h)

def child_pids(root):
    if os.name!='nt':return [root]
    class PE(C.Structure):_fields_=[('dwSize',W.DWORD),('cntUsage',W.DWORD),('th32ProcessID',W.DWORD),('th32DefaultHeapID',C.c_size_t),('th32ModuleID',W.DWORD),('cntThreads',W.DWORD),('th32ParentProcessID',W.DWORD),('pcPriClassBase',W.LONG),('dwFlags',W.DWORD),('szExeFile',W.WCHAR*260)]
    K.CreateToolhelp32Snapshot.restype=W.HANDLE;K.Process32FirstW.argtypes=[W.HANDLE,C.POINTER(PE)];K.Process32NextW.argtypes=[W.HANDLE,C.POINTER(PE)]
    snap=K.CreateToolhelp32Snapshot(2,0);e=PE();e.dwSize=C.sizeof(e);pairs=[]
    try:
        ok=K.Process32FirstW(snap,C.byref(e))
        while ok:pairs.append((e.th32ProcessID,e.th32ParentProcessID));ok=K.Process32NextW(snap,C.byref(e))
    finally:K.CloseHandle(snap)
    pids={root}
    for _ in range(len(pairs)):
        before=len(pids);pids.update(p for p,parent in pairs if parent in pids)
        if len(pids)==before:break
    return sorted(pids)

class Job:
    """Terminate owned descendants when the harness exits, including launcher orphans."""
    def __init__(self):
        if os.name!='nt':raise OSError('WINDOWS_JOB_REQUIRED')
        class BASIC(C.Structure):_fields_=[('PerProcessUserTimeLimit',C.c_longlong),('PerJobUserTimeLimit',C.c_longlong),('LimitFlags',W.DWORD),('MinimumWorkingSetSize',C.c_size_t),('MaximumWorkingSetSize',C.c_size_t),('ActiveProcessLimit',W.DWORD),('Affinity',C.c_size_t),('PriorityClass',W.DWORD),('SchedulingClass',W.DWORD)]
        class IO(C.Structure):_fields_=[(x,C.c_ulonglong) for x in ('ReadOperationCount','WriteOperationCount','OtherOperationCount','ReadTransferCount','WriteTransferCount','OtherTransferCount')]
        class EXT(C.Structure):_fields_=[('BasicLimitInformation',BASIC),('IoInfo',IO),('ProcessMemoryLimit',C.c_size_t),('JobMemoryLimit',C.c_size_t),('PeakProcessMemoryUsed',C.c_size_t),('PeakJobMemoryUsed',C.c_size_t)]
        K.CreateJobObjectW.restype=W.HANDLE;K.CreateJobObjectW.argtypes=[C.c_void_p,W.LPCWSTR];K.SetInformationJobObject.argtypes=[W.HANDLE,C.c_int,C.c_void_p,W.DWORD];K.AssignProcessToJobObject.argtypes=[W.HANDLE,W.HANDLE];K.TerminateJobObject.argtypes=[W.HANDLE,W.UINT]
        self.handle=K.CreateJobObjectW(None,None)
        if not self.handle:raise OSError('CREATE_JOB_FAILED')
        info=EXT();info.BasicLimitInformation.LimitFlags=0x2000
        if not K.SetInformationJobObject(self.handle,9,C.byref(info),C.sizeof(info)):
            self.close();raise OSError('JOB_LIMIT_SETUP_FAILED')
    def add(self,p):
        if not K.AssignProcessToJobObject(self.handle,W.HANDLE(int(p._handle))):raise OSError('ASSIGN_PROCESS_JOB_FAILED')
    def close(self):
        if getattr(self,'handle',None):K.CloseHandle(self.handle);self.handle=None

