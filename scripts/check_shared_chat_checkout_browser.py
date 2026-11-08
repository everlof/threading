"""Drive the opt-in checkout fixture with the shipping browser client (requires Playwright).

Start RemoteDormantSessionStartupTests/testSharedChatReconnectsAfterCheckoutMoveWithoutEndingOrRepeatingInput
with THREADING_CHECKOUT_BROWSER_PROOF pointing to a fresh directory, then pass that directory
to this script. All credentials and chats belong to the isolated hosted test.
"""

import json
import pathlib
import sys
import time
from playwright.sync_api import sync_playwright

root = pathlib.Path(sys.argv[1])
deadline = time.monotonic() + 90
while not (root / 'url').exists():
    if time.monotonic() >= deadline:
        raise RuntimeError('Fixture URL did not arrive')
    time.sleep(0.1)
url = (root / 'url').read_text()
with sync_playwright() as p:
    browser = p.chromium.launch(headless=True)
    page = browser.new_page(viewport={'width': 1100, 'height': 800})
    page.add_init_script("localStorage.setItem('threading.device', 'browser');")
    proof = {'hellos': 0, 'ended': [], 'submissions': []}

    def receive(payload):
        if not isinstance(payload, str):
            return
        message = json.loads(payload)
        if message['type'] == 'hello':
            proof['hellos'] += 1
        elif message['type'] == 'ended':
            proof['ended'].append(message.get('reason'))
        elif message['type'] == 'submitResult':
            proof['submissions'].append(message['status'])

    def observe_socket(socket):
        if '/ws/session/' in socket.url:
            socket.on('framereceived', receive)

    def wait_until(condition, timeout=20):
        deadline = time.monotonic() + timeout
        while not condition():
            if time.monotonic() >= deadline:
                page.screenshot(path=str(root / 'failure.png'))
                raise AssertionError(f'Browser did not settle: {proof}')
            # Pump Playwright events without evaluating strings inside the client's strict CSP.
            page.wait_for_timeout(50)

    page.on('websocket', observe_socket)
    page.goto(url)
    page.locator('#sessions button').first.click()
    wait_until(lambda: proof['hellos'] == 1)
    page.locator('#terminalPrompt').fill('Draft survives the checkout move')
    (root / 'move').touch()
    wait_until(lambda: proof['hellos'] == 2)
    assert page.locator('#terminalPrompt').input_value() == 'Draft survives the checkout move'
    assert proof['ended'] == []
    page.locator('#terminalSend').click()
    wait_until(lambda: 'accepted' in proof['submissions'])
    page.screenshot(path=str(root / 'reconnected.png'))
    print(json.dumps({'result': 'reconnected', 'draftPreserved': True,
                      'wire': proof}), flush=True)
    (root / 'reconnected').touch()
    wait_until(lambda: len(proof['ended']) == 1)
    print(json.dumps({'genuineStop': proof['ended']}), flush=True)
    browser.close()
