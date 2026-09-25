"""Hold a shell-like PTY long enough for the AT-SPI client to inspect its title."""
import os
import time

os.write(1, b'\x1b]0;A11Y TERMINAL READY\x07')
time.sleep(15)
