import os

import redis
from flask import Flask, redirect, render_template, request

app = Flask(__name__)
cache = redis.from_url(os.environ.get("REDIS_URL", "redis://localhost:6379"),
                       decode_responses=True)

TITULO = os.environ.get("TITULO_APP", "Tablón de notas")


@app.get("/")
def portada():
    notas = cache.lrange("notas", 0, 49)
    return render_template("index.html", titulo=TITULO, notas=notas)


@app.post("/notas")
def crear():
    texto = (request.form.get("texto") or "").strip()
    if texto:
        cache.lpush("notas", texto)
        cache.ltrim("notas", 0, 49)
    return redirect("/")


@app.get("/salud")
def salud():
    try:
        cache.ping()
    except redis.RedisError:
        return {"estado": "sin cache"}, 503
    return {"estado": "ok", "notas": cache.llen("notas")}


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8000, debug=True)
