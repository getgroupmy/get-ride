# get.ride face match server (see README.md). linux/amd64, no AVX needed:
# OpenCV's cv2.dnn runs YuNet and SFace (opencv_zoo, Apache 2.0).
FROM python:3.11.10-slim-bookworm

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# The two models, from opencv_zoo at a fixed commit, checked by sha256: the
# build stops if either is not exactly the file expected. (Python fetches
# them: the slim image has no curl, and Synology's builder may not know
# ADD --checksum.)
ARG ZOO=https://media.githubusercontent.com/media/opencv/opencv_zoo/48b10fa505aeb51fbd127fc60a5c660040e823b7/models
COPY fetch_models.py /tmp/
RUN python /tmp/fetch_models.py "$ZOO" /app/models && rm /tmp/fetch_models.py

COPY core.py app.py ./

RUN useradd --system --no-create-home face
USER face

ENV PYTHONUNBUFFERED=1 FACE_MODELS_DIR=/app/models
EXPOSE 8000
HEALTHCHECK --interval=60s --timeout=10s --start-period=30s \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=5)"
# One worker: one copy of the models in memory.
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "1", "--no-server-header"]
