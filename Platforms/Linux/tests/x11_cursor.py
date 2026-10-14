"""Read the cursor actually installed on the X server, independently of shim state."""
import ctypes
import hashlib
from pathlib import Path
import struct
import time
import zlib


class CursorImage(ctypes.Structure):
    _fields_ = [
        ('x', ctypes.c_short), ('y', ctypes.c_short),
        ('width', ctypes.c_ushort), ('height', ctypes.c_ushort),
        ('xhot', ctypes.c_ushort), ('yhot', ctypes.c_ushort),
        ('serial', ctypes.c_ulong), ('pixels', ctypes.POINTER(ctypes.c_ulong)),
        ('atom', ctypes.c_ulong), ('name', ctypes.c_char_p),
    ]


class NativeCursor:
    def __init__(self):
        self.x11 = ctypes.CDLL('libX11.so.6')
        self.fixes = ctypes.CDLL('libXfixes.so.3')
        self.x11.XOpenDisplay.argtypes = [ctypes.c_char_p]
        self.x11.XOpenDisplay.restype = ctypes.c_void_p
        self.x11.XCloseDisplay.argtypes = [ctypes.c_void_p]
        self.x11.XFree.argtypes = [ctypes.c_void_p]
        self.fixes.XFixesGetCursorImage.argtypes = [ctypes.c_void_p]
        self.fixes.XFixesGetCursorImage.restype = ctypes.POINTER(CursorImage)
        self.x11.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
        self.x11.XDefaultRootWindow.restype = ctypes.c_ulong
        self.x11.XWarpPointer.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_ulong,
                                          ctypes.c_int, ctypes.c_int, ctypes.c_uint, ctypes.c_uint,
                                          ctypes.c_int, ctypes.c_int]
        self.x11.XSync.argtypes = [ctypes.c_void_p, ctypes.c_int]
        self.display = self.x11.XOpenDisplay(None)
        assert self.display, 'X11 cursor observer could not open display'

    def park(self):
        """Move the pointer to the root window's corner, outside any journey window.

        The installed lane shares one X display between journeys, so the pointer starts wherever
        the previous client left it. A window mapped under that stationary pointer can change its
        cursor before any pointer motion, and Xvfb then shows later cursor changes only after the
        pointer moves again. Starting outside the window gives every journey the fresh display's
        ordering: the pointer enters through motion.
        """
        root = self.x11.XDefaultRootWindow(self.display)
        self.x11.XWarpPointer(self.display, 0, root, 0, 0, 0, 0, 0, 0)
        self.x11.XSync(self.display, 0)

    def close(self):
        if self.display:
            self.x11.XCloseDisplay(self.display)
            self.display = None

    def settled(self, destination=None, timeout=5, interval=.15):
        """The installed cursor once two spaced reads agree.

        A client sets its cursor after rendering, but the X server applies the request only when
        that client next flushes its connection. A read taken as soon as a frame is published can
        therefore still return the previous cursor; a reference cursor must not be one of those.
        """
        deadline = time.monotonic() + timeout
        previous = self.read()
        while time.monotonic() < deadline:
            time.sleep(interval)
            current = self.read()
            if current == previous:
                return self.read(destination) if destination else current
            previous = current
        raise AssertionError('native cursor did not settle')

    def read(self, destination=None):
        image = self.fixes.XFixesGetCursorImage(self.display)
        assert image, 'X server supplied no cursor image'
        try:
            value = image.contents
            assert 0 < value.width <= 256 and 0 < value.height <= 256
            rgba = bytearray()
            for index in range(value.width * value.height):
                pixel = value.pixels[index]
                rgba.extend(((pixel >> 16) & 255, (pixel >> 8) & 255, pixel & 255, (pixel >> 24) & 255))
            geometry = struct.pack('>4H', value.width, value.height, value.xhot, value.yhot)
            if destination:
                def chunk(kind, data):
                    return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
                rows = b''.join(b'\0' + rgba[row * value.width * 4:(row + 1) * value.width * 4]
                                for row in range(value.height))
                png = (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>2I5B', value.width,
                       value.height, 8, 6, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b''))
                Path(destination).write_bytes(png)
            return hashlib.sha256(geometry + rgba).hexdigest()
        finally:
            self.x11.XFree(image)
