#!/usr/bin/env python3
import json
import os
import urllib.request

BASE = f"http://127.0.0.1:{os.environ['CMDY_PORT']}"
HEADERS = {
    "Authorization": f"Bearer {os.environ['CMDY_TOKEN']}",
    "Content-Type": "application/json",
}


def request(method, path, body=None):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(BASE + path, data, HEADERS, method=method)
    with urllib.request.urlopen(req) as response:
        return json.load(response)


def post(path, body=None):
    return request("POST", path, body or {})


def patch(path, body):
    return request("PATCH", path, body)


def events():
    req = urllib.request.Request(BASE + "/v1/events", headers=HEADERS)
    with urllib.request.urlopen(req) as stream:
        for raw in stream:
            if raw.startswith(b"data: "):
                yield json.loads(raw[6:])
