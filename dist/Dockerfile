# OnlyOffice DocumentServer 9.4.0 — analytics removed
#
# Base: official onlyoffice/documentserver:9.4.0 (latest stable, multi-arch).
# Overlay: the 5 main editors (document/spreadsheet/presentation/pdf/visio),
# rebuilt from web-apps `release/v9.4.0` with commit 48dcc5c
# ("[all] removed Analytic module sources") applied. This strips the Google
# Analytics module and all trackEvent() calls from the editor `code.js` bundles.
#
# Architecture-independent: the overlay is pure JS/HTML/CSS, so the same files
# are layered onto each platform's base image with no per-arch rebuild.
FROM onlyoffice/documentserver:9.4.0

COPY --chown=ds:ds apps/ /var/www/onlyoffice/documentserver/web-apps/apps/
