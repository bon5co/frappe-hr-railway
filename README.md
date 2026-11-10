# frappe-hr-railway

Railway wrapper image for Frappe HR (ERPNext + the HRMS app) from `ghcr.io/frappe/hrms`.
One container runs nginx, gunicorn, socket.io, the worker, the scheduler and redis under
honcho; MariaDB is the second Railway service. Site `hr` is created on first boot and the
Administrator API key pair comes from `FRAPPE_API_KEY` / `FRAPPE_API_SECRET`.

Image: `ghcr.io/bon5co/frappe-hr-railway`. The base is pinned by digest because the
`v16.x` tags of `ghcr.io/frappe/hrms` hold version-15 content.
