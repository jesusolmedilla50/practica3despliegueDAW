FROM python:latest

RUN apt-get update && apt-get install -y python3-pip curl vim git

WORKDIR /app
COPY . .

RUN pip install -r requirements.txt

ENV REDIS_URL=redis://cache:6379
ENV CLAVE_ADMIN=admin1234

CMD python app.py
