"""Offline lifecycle checks for the bundled adapter; never connects to a phone."""
import asyncio
import importlib.machinery
import importlib.util
import pathlib
import sys
import types
import unittest
from contextlib import asynccontextmanager
from unittest.mock import patch

PATH = pathlib.Path(__file__).resolve().parents[2] / "Sources/Threading/Resources/physical_device_session.py.txt"
loader = importlib.machinery.SourceFileLoader("physical_device_session", str(PATH))
helper = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
loader.exec_module(helper)


class AdapterTests(unittest.IsolatedAsyncioTestCase):
    async def exercise(self, commands, *, wrong_device=False, cancel=False):
        self.events = []

        @asynccontextmanager
        async def tunnel(serial):
            self.assertEqual(serial, "PHONE")
            self.events.append("tunnel-open")
            try:
                yield types.SimpleNamespace(udid="OTHER" if wrong_device else serial)
            finally:
                self.events.append("tunnel-close")

        async def send(state, x, y):
            self.events.append((state, x, y))

        @asynccontextmanager
        async def touch(rsd):
            self.events.append("hid-open")
            try:
                yield types.SimpleNamespace(send_touchscreen=send)
            finally:
                self.events.append("hid-close")

        async def requests():
            for command in commands:
                yield command.split()
            if cancel:
                raise asyncio.CancelledError()

        modules = {
            "pymobiledevice3.remote.native_tunnel": types.SimpleNamespace(NativeRemotedTunnel=tunnel),
            "pymobiledevice3.remote.core_device.hid_service": types.SimpleNamespace(
                touch_session=touch, TOUCHSCREEN_STATE_CONTACT=1, TOUCHSCREEN_STATE_RELEASE=0
            ),
        }
        with patch.dict(sys.modules, modules), patch.object(helper, "requests", requests), patch.object(helper, "reply"):
            await helper.run("PHONE", "control")

    async def test_eof_releases_held_contact_and_closes_sessions(self):
        await self.exercise(["ready", "down 1 2", "move 3 4"])
        self.assertEqual(self.events, ["tunnel-open", "hid-open", (1, 1, 2), (1, 3, 4),
                                       (0, 3, 4), "hid-close", "tunnel-close"])

    async def test_cancel_releases_held_contact(self):
        with self.assertRaises(asyncio.CancelledError):
            await self.exercise(["down 1 2"], cancel=True)
        self.assertEqual(self.events[-3:], [(0, 1, 2), "hid-close", "tunnel-close"])

    async def test_invalid_sequence_fails_closed_and_releases(self):
        with self.assertRaises(ValueError):
            await self.exercise(["down 1 2", "down 3 4"])
        self.assertEqual(self.events[-3:], [(0, 1, 2), "hid-close", "tunnel-close"])

    async def test_wrong_device_never_opens_hid(self):
        with self.assertRaises(ValueError):
            await self.exercise(["down 1 2"], wrong_device=True)
        self.assertEqual(self.events, ["tunnel-open", "tunnel-close"])

    async def test_normal_up_is_not_repeated_at_eof(self):
        await self.exercise(["down 1 2", "up 3 4"])
        self.assertEqual([event for event in self.events if isinstance(event, tuple)], [(1, 1, 2), (0, 3, 4)])

    def test_coordinate_validation(self):
        self.assertEqual(helper.point(["move", "0", "65535"]), (0, 65535))
        for command in [["move", "-1", "0"], ["move", "0", "65536"], ["up"], ["up", "nan", "0"]]:
            with self.assertRaises(ValueError):
                helper.point(command)


if __name__ == "__main__":
    unittest.main()
