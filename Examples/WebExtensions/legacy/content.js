browser.runtime.sendMessage({type: 'ping'}).then(message => {
  const marker = document.createElement('p'); marker.id = 'legacy'; marker.textContent = message; document.body.append(marker);
});
