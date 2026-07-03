# Imagen ligera para el proxy OAuth en Cloud Run
FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY main.py .

ENV PORT=8080
EXPOSE 8080

# gunicorn: 1 worker es suficiente, Cloud Run escala horizontalmente
# con más instancias si hay concurrencia
CMD exec gunicorn --bind :$PORT --workers 1 --threads 8 --timeout 30 main:app
