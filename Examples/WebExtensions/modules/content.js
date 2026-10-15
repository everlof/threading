(globalThis.browser || chrome).runtime.sendMessage({type: 'ping'}).then(message => {
  const marker = document.createElement('p'); marker.id = 'module'; marker.textContent = message; document.body.append(marker);
});
