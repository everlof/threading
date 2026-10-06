"""Read the cursor actually installed on the X server, independently of shim state."""
import ctypes
import hashlib
from pathlib import Path
import struct
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
        self.display = self.x11.XOpenDisplay(None)
        assert self.display, 'X11 cursor observer could not open display'

    def close(self):
        if self.display:
            self.x11.XCloseDisplay(self.display)
            self.display = None

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
