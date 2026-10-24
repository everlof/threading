# Traffic Mock Example

This safe extension contributes one static response fixture through the public manifest API.
After packaging, installing and enabling it, start traffic capture with:

```json
{"hosts":[],"mock_extension":"codes.threading.example.traffic-mock"}
```

Send `GET http://127.0.0.1:8080/v1/items` through the returned proxy endpoint. The response is
`{"items":[]}` even if no server listens on port 8080. Other paths forward normally. Use
`traffic_list` and `traffic_get` to see `mocked: true` and the captured response. This fixture is
plain HTTP so no certificate setup is needed. The extension process is idle; matching and response
delivery belong to the host-owned proxy helper.
