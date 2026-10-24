# get.ride face match server (see README.md). x86-64 with AVX.
FROM python:3.11-slim

# OpenCV's libraries.
RUN apt-get update \
 && apt-get install -y --no-install-recommends libgl1 libglib2.0-0 \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Dlib is optional (docker compose build --build-arg WITH_DLIB=1): it is
# compiled here, which takes a while and needs cmake.
ARG WITH_DLIB=0
RUN if [ "$WITH_DLIB" = "1" ]; then \
      apt-get update && apt-get install -y --no-install-recommends build-essential cmake \
      && pip install --no-cache-dir dlib==19.24.6 \
      && apt-get purge -y build-essential cmake && apt-get autoremove -y && rm -rf /var/lib/apt/lists/*; \
    fi

COPY core.py app.py ./

# The model's weights are fetched once into /root/.deepface (a volume).
ENV PYTHONUNBUFFERED=1 TF_CPP_MIN_LOG_LEVEL=2
EXPOSE 8000
HEALTHCHECK --interval=60s --timeout=10s --start-period=120s \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=5)"
# One worker: one copy of the model in memory.
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "1", "--no-server-header"]
