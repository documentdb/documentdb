FROM python:3.13-slim

WORKDIR /app
RUN pip install --no-cache-dir "pymongo>=4.6"
COPY app.py .

CMD ["python", "app.py"]
