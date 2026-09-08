#!/usr/bin/env python3
"""Signed calls to the OVH API.

    OVH_EP=ovh-us OVH_AK=.. OVH_AS=.. OVH_CK=.. ovh-api.py GET /vps

OVH does not use a bearer token. Each request carries a SHA1 signature over
the application secret, consumer key, method, full URL, body and a timestamp,
and the timestamp must come from OVH's clock rather than ours -- a skewed local
clock is otherwise indistinguishable from a bad secret.

Exists so the shell scripts do not each reimplement the signing.
"""
import hashlib
import json
import os
import sys
import urllib.error
import urllib.request

ENDPOINTS = {
    "ovh-eu": "https://eu.api.ovh.com/1.0",
    "ovh-us": "https://api.us.ovhcloud.com/1.0",
    "ovh-ca": "https://ca.api.ovh.com/1.0",
}

_time_cache = {}


def base_url():
    ep = os.environ.get("OVH_EP", "ovh-us")
    if ep not in ENDPOINTS:
        sys.exit("unknown OVH endpoint %r (expected one of %s)" % (ep, ", ".join(ENDPOINTS)))
    return ENDPOINTS[ep]


def server_time(base):
    if base not in _time_cache:
        _time_cache[base] = urllib.request.urlopen(base + "/auth/time", timeout=15).read().decode().strip()
    return _time_cache[base]


def call(method, path, body=""):
    base = base_url()
    ak, as_, ck = os.environ["OVH_AK"], os.environ["OVH_AS"], os.environ["OVH_CK"]
    url = base + path
    ts = server_time(base)
    raw = "+".join([as_, ck, method, url, body, ts])
    sig = "$1$" + hashlib.sha1(raw.encode()).hexdigest()

    req = urllib.request.Request(url, method=method, data=body.encode() if body else None)
    req.add_header("X-Ovh-Application", ak)
    req.add_header("X-Ovh-Consumer", ck)
    req.add_header("X-Ovh-Timestamp", ts)
    req.add_header("X-Ovh-Signature", sig)
    req.add_header("Content-Type", "application/json")
    try:
        return json.loads(urllib.request.urlopen(req, timeout=30).read().decode() or "null")
    except urllib.error.HTTPError as e:
        detail = e.read().decode()[:300]
        raise SystemExit("OVH %s %s -> %d %s" % (method, path, e.code, detail))


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    out = call(sys.argv[1], sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else "")
    json.dump(out, sys.stdout, indent=2)
    print()
