(() => {
  const api = globalThis.browser || chrome;
  api.runtime.sendMessage({type: 'ping'}).then(reply => {
    const marker = document.createElement('p');
    marker.id = 'coverage-content'; marker.textContent = reply.text;
    document.body.append(marker);
    console.info(window === top ? 'coverage-content-top' : 'coverage-content-child');
  });
})();
