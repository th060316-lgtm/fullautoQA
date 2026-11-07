"""Isolated window for real keyboard/capture verification; not a gameplay fixture."""
import tkinter as tk,json,sys
from pathlib import Path
p=Path(sys.argv[1]);app=tk.Tk();app.title('QA Harness Input Probe');app.geometry('640x400+40+40');app.configure(bg='#1d5078')
tk.Label(app,text='QA HARNESS SELF TEST\nPress A (automated)',bg='#1d5078',fg='white',font=('Arial',22)).pack(pady=60)
def key(e):
    p.write_text(json.dumps({'key':e.keysym,'character':e.char}),encoding='utf-8')
app.bind('<KeyPress>',key);app.after(20000,app.destroy);app.mainloop()
