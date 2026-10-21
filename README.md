# Tablón de notas

Aplicación web mínima (Flask + Redis) para publicar y consultar un tablón de notas
compartido. Todo el estado vive en Redis; la aplicación es sin estado.

## Arquitectura

| Contenedor | Imagen                                                   | Puertos             | Función                                   |
|------------|----------------------------------------------------------|---------------------|-------------------------------------------|
| `web`      | `notas-web:latest` (se construye con el `Dockerfile`)     | `8000` publicado en el host | Aplicación Flask servida por gunicorn |
| `cache`    | `redis:7.4-alpine`                                         | **ninguno publicado** | Guarda las notas |

- `web` arranca **después** de que `cache` esté sano (`depends_on` + `condition: service_healthy`).
- `web` corre como usuario **sin privilegios** (`app`, uid 10001); `cache` corre como `redis`.
- Redis **no** publica ningún puerto: solo es alcanzable desde la red interna de
  Compose, con el nombre de servicio `cache`.

## Requisitos

- **Docker Engine** >= 20.10 -> `docker --version`
- **Plugin Docker Compose v2** (no el `docker-compose` v1 heredado) -> `docker compose version`
- **Puerto 8000 libre** en el host, que es el que se publica. Si está ocupado, cambia
  `"8000:8000"` por otro, p. ej. `"8080:8000"`, en `docker-compose.yml` y actualiza las URL
  de este README.
- ~500 MB de disco para las imágenes y unos pocos MB para los datos.
- **No** hace falta instalar Python ni Redis en la máquina: todo va en contenedores.

## Estructura del proyecto

```
.
├── app.py                 # aplicación Flask: rutas /, /notas y /salud
├── requirements.txt       # dependencias fijadas (Flask, redis, gunicorn)
├── Dockerfile             # imagen de la app (python:3.12-slim + gunicorn + usuario no root)
├── .dockerignore          # excluye del contexto de build .git, .env, sin-revisar/, etc.
├── docker-compose.yml     # orquestación de los servicios web y cache
├── templates/index.html   # plantilla Jinja2 de la portada
└── sin-revisar/           # material de auditoría: NO se usa para desplegar
```

## Variables de entorno

Todas se declaran en `docker-compose.yml`, **nunca dentro de la imagen**.

| Variable     | Servicio | Valor por defecto    | Para qué sirve                                                                                     |
|--------------|----------|----------------------|----------------------------------------------------------------------------------------------------|
| `REDIS_URL`  | `web`    | `redis://cache:6379` | Dirección de Redis. `cache` es el nombre del servicio en la red de Compose. Sin ella la app usaría `redis://localhost:6379` (`app.py:7`), que **no** funciona dentro del contenedor. |
| `TITULO_APP` | `web`    | `Tablón de notas`    | Título de la página. Se lee al arrancar el proceso, así que cambiarla exige recrear el contenedor.   |

Para cambiarlas, edita el bloque `environment:` del servicio `web` y recrea:

```bash
docker compose up -d --force-recreate web
```

**Sobre `CLAVE_ADMIN`:** aparece en `sin-revisar/`, pero la aplicación **no la usa**
(`grep -rn CLAVE_ADMIN app.py` no devuelve nada). No está ni en la imagen ni en el
compose, y no hay ningún secreto en este despliegue.

## Puesta en marcha

```bash
# 1. Construir la imagen y levantar los dos servicios
docker compose up -d --build

# 2. Comprobar el estado
docker compose ps
```

Salida esperada:

```
NAME           IMAGE               STATUS                   PORTS
notas-cache-1  redis:7.4-alpine    Up 2 minutes (healthy)   6379/tcp
notas-web-1    notas-web:latest    Up 2 minutes (healthy)   0.0.0.0:8000->8000/tcp
```

- La primera vez tarda más: descarga `python:3.12-slim` y `redis:7.4-alpine`.
- Los dos servicios deben aparecer como **healthy**: `cache` por su healthcheck
  (`redis-cli ping`) y `web` por su `HEALTHCHECK`, que consulta `/salud`.
- La aplicación queda en **http://localhost:8000**.

## Pruebas de comprobación

```bash
# 1. Estado de salud (el mismo endpoint que usa el HEALTHCHECK del contenedor)
curl -s http://localhost:8000/salud
# {"estado": "ok", "notas": 0}

# 2. La portada responde y trae la lista de notas
curl -s http://localhost:8000/ | grep -o '<li>' | wc -l
# 0

# 3. Alta de una nota (responde 302, redirección a /)
curl -s -o /dev/null -w '%{http_code}\n' -X POST -d 'texto=Nota de prueba' http://localhost:8000/notas
# 302

# 4. La nota ya está guardada
curl -s http://localhost:8000/salud
# {"estado": "ok", "notas": 1}
curl -s http://localhost:8000/ | grep 'Nota de prueba'

# 5. Qué servidor responde por delante (gunicorn, no el de desarrollo de Flask)
curl -sI http://localhost:8000/ | grep -i '^server'
# Server: gunicorn

# 6. Usuario real del contenedor
docker compose exec web id
# uid=10001(app) gid=10001(app) groups=10001(app)

# 7. El contenido de la imagen es el esperado (sin .git ni .env)
docker compose exec web ls -a /app
# .  ..  app.py  requirements.txt  templates
```

### Persistencia

```bash
# Reiniciar los contenedores: las notas deben seguir ahí
docker compose restart
curl -s http://localhost:8000/salud
# {"estado": "ok", "notas": 1}

# El volumen es lo que las guarda
docker volume ls | grep notas
docker compose exec cache ls -la /data
```

### Comprobar que el borrado de datos funciona

```bash
docker compose down -v          # borra contenedores, red y volumen
docker compose up -d
curl -s http://localhost:8000/salud
# {"estado": "ok", "notas": 0}   <- las notas han desaparecido con el volumen
```

## Dónde quedan los datos

- **Dentro del contenedor `cache`**, en `/data`: `dump.rdb` (RDB) y `appendonlydir/` (AOF,
  activado con `--appendonly yes`).
- **En el host**, en el volumen Docker con nombre **`notas-redis-data`** (declarado al final
  de `docker-compose.yml`). No es una carpeta del proyecto: la gestiona Docker.

  ```bash
  docker volume inspect notas-redis-data
  ```

- **Clave de Redis**: `notas`, una lista con las **50 últimas** notas
  (`lpush` + `ltrim 0 49`, `app.py:22-24`). Al superar 50 se descartan las más antiguas.
- **La aplicación no guarda nada en disco**: no hay base de datos ni ficheros; todo el
  estado está en Redis. Por eso, si borras el volumen, las notas desaparecen.

```bash
docker compose exec cache redis-cli LLEN notas
docker compose exec cache redis-cli LRANGE notas 0 4
```

## Cómo ver los registros

```bash
# Todos los servicios, en tiempo real
docker compose logs -f

# Solo de la aplicación
docker compose logs -f web

# Solo de Redis
docker compose logs -f cache

# Últimas líneas sin seguir el flujo
docker compose logs --tail=50 web

# Con marcas de tiempo
docker compose logs -f --timestamps web
```

- El access log y el error log de gunicorn van a **stdout** (`--access-logfile -`), así que
  `docker compose logs web` muestra cada petición con su código, método, ruta y duración.
- Para ver los procesos: `docker compose top`.

## Cómo parar y limpiar

```bash
# Parar los contenedores (conservan los datos)
docker compose stop

# Volver a arrancarlos
docker compose start

# Parar y eliminar contenedores y red (conserva el volumen de datos)
docker compose down

# Parar y eliminar contenedores, red y volumen de datos (las notas se pierden)
docker compose down -v

# Eliminar la imagen de la aplicación
docker image rm notas-web:latest

# Eliminar también la de Redis (opcional)
docker image rm redis:7.4-alpine
```

Limpieza completa recomendada:

```bash
docker compose down -v
docker image rm notas-web:latest
```

## Despliegue reproducible

Para comprobar que este README basta para reconstruir el entorno desde cero:

```bash
docker compose down -v
docker image rm notas-web:latest
docker compose up -d --build
curl -s http://localhost:8000/salud
# {"estado": "ok", "notas": 0}
```

## Notas de seguridad

- El contenedor `web` **no** corre como root, sino como el usuario `app` (uid 10001).
- La aplicación se sirve con **gunicorn**; no se usa el servidor de desarrollo de Flask
  ni el modo debug.
- Redis no publica ningún puerto y no lleva contraseña porque no es alcanzable desde
  fuera de la red de Compose.
- `.git`, `.env` y `sin-revisar/` están en `.dockerignore`: no entran en la imagen.
- No hay secretos ni datos personales ni en la imagen ni en el compose.

## `sin-revisar/`

Contenedorización que entregó un compañero y que **no** se usa para desplegar (está
excluida del contexto de build por `.dockerignore`). Contiene un `Dockerfile` y un
`docker-compose.yml` con problemas de base: `python:latest`, `apt-get install` de
paquetes innecesarios, `COPY . .` sin `.dockerignore`, `CLAVE_ADMIN` horneado en la
imagen, arranque con `python app.py` en modo `debug=True` (servidor de desarrollo de
Flask), ejecución como root, Redis con el puerto `6379` publicado al exterior, sin
volumen de persistencia y sin healthchecks.
