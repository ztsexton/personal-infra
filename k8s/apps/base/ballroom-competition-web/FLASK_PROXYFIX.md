# Flask ProxyFix Configuration

To make your Flask app work with the path prefix WITHOUT changing routes, add this to your app initialization:

```python
from flask import Flask
from werkzeug.middleware.proxy_fix import ProxyFix

app = Flask(__name__)

# This makes Flask respect X-Forwarded-Prefix header from Traefik
app.wsgi_app = ProxyFix(
    app.wsgi_app,
    x_for=1,
    x_proto=1,
    x_host=1,
    x_prefix=1
)

# Your routes stay the same:
@app.route('/')
@app.route('/judges')
@app.route('/couples')
# etc...
```

**What this does:**
- Traefik sends `X-Forwarded-Prefix: /ballroomcomp` header
- Strips `/ballroomcomp` from the request path before sending to Flask
- ProxyFix tells Flask to prepend `/ballroomcomp` to all generated URLs
- Your app works both at root (`/`) AND under prefix (`/ballroomcomp`) without code changes

**No route changes needed!** This is the standard way to run WSGI apps behind reverse proxies.
