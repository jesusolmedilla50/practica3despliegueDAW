# syntax=docker/dockerfile:1
FROM python:3.12-slim

LABEL maintainer="practica-ut3"

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /app

# Dependencias primero: solo requirements.txt, para que la capa de pip
# se reutilice en cache aunque cambie el codigo de la aplicacion.
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

# Usuario del sistema sin privilegios (uid/gid fijos, sin shell de login).
RUN groupadd --system --gid 10001 app \
    && useradd --system --uid 10001 --gid 10001 \
        --no-create-home --home-dir /nonexistent \
        --shell /usr/sbin/nologin app

# El resto del codigo, con ownership del usuario no privilegiado.
COPY --chown=app:app app.py ./
COPY --chown=app:app templates/ ./templates/

USER app

# Puerto que escucha la aplicacion (gunicorn, ver CMD).
EXPOSE 8000

# Healthcheck contra /salud. La imagen slim no trae curl -> urllib de la stdlib.
# Un 503 (Redis caido) hace fallar la comprobacion -> contenedor "unhealthy".
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD ["python", "-c", "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/salud', timeout=3).status == 200 else 1)"]

# Arranque con gunicorn (no el servidor de desarrollo de Flask), CMD en JSON.
CMD ["gunicorn", "--bind", "0.0.0.0:8000", "--workers", "2", "--threads", "4", "--timeout", "30", "--access-logfile", "-", "--error-logfile", "-", "app:app"]
