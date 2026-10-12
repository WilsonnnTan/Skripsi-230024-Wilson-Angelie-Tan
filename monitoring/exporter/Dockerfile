# =============================================================================
# h2load live metrics exporter — minimal stdlib-only Python image.
# =============================================================================
FROM python:3.12-slim

COPY h2load_exporter.py /app/h2load_exporter.py
WORKDIR /app

EXPOSE 9115
ENTRYPOINT ["python3", "/app/h2load_exporter.py"]
