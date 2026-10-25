# GET.ride document reader for the office NAS (see README.md). linux/amd64,
# no AVX needed: PP-OCR runs through OpenVINO on the processor.
FROM python:3.11.10-slim-bookworm

RUN apt-get update && apt-get install -y --no-install-recommends libgl1 libglib2.0-0 \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Fetch the OCR models into the image now, so the reader starts offline.
RUN python -c "from rapidocr import RapidOCR, EngineType as E; RapidOCR(params={'Det.engine_type':E.OPENVINO,'Cls.engine_type':E.OPENVINO,'Rec.engine_type':E.OPENVINO})"

COPY core.py reader.py ./

RUN useradd --system --create-home reader && mkdir -p /data && chown reader /data \
 && chown -R reader /usr/local/lib/python3.11/site-packages/rapidocr/models
USER reader

ENV PYTHONUNBUFFERED=1 READER_DATA=/data
CMD ["python", "reader.py"]
