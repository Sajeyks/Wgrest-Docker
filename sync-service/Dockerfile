FROM python:3.11-alpine

WORKDIR /app

# Install dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy all modular components
COPY config.py .
COPY encryption.py .
COPY wgrest_api.py .
COPY config_parser.py .
COPY database.py .
COPY webhook.py .
COPY file_watcher.py .
COPY data_processor.py .
COPY sync_modular.py .

# Use the modular sync service as entry point
CMD ["python", "sync_modular.py"]