"""Exercise visible Unicode, concealed cells, scrollback, and a live text change."""
import os
import tty
import time

tty.setraw(0)
os.write(1, b'OFFSCREEN_ONLY\r\n' + b'filler\r\n' * 30)
os.write(1, 'VISIBLE 界 e\u0301\r\n'.encode())
os.write(1, b'\x1b[8mCONCEALED_MARKER\x1b[0m\r\n')
os.write(1, b'\x1b]0;A11Y TERMINAL READY\x07')
os.read(0, 1)
os.write(1, b'\x1b[2J\x1b[HUPDATED VISIBLE\r\n')
time.sleep(10)
