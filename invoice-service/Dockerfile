FROM python:3.12-slim

WORKDIR /app

# Install deps first for cache friendliness.
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py ./

# Run as non-root.
RUN useradd --create-home --shell /bin/bash app
USER app

EXPOSE 8081

CMD ["python", "app.py"]
